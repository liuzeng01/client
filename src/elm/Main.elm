port module Main exposing (..)


import Tuple exposing (first, second)

import Html exposing (..)
import Html.Attributes exposing (style)
import Html.Events exposing (onClick)
import Html.Lazy exposing (lazy, lazy2)
import Json.Decode as Json
import Json.Encode exposing (..)
import Dom
import Task

import Types exposing (..)
import Trees exposing (..)
import TreeUtils exposing (..)
import Sha1 exposing (timestamp)
import Objects


main : Program Json.Value Model Msg
main =
  programWithFlags
    { init = init
    , view = view
    , update = update
    , subscriptions = subscriptions
    }


port js : (String, Json.Value) -> Cmd msg
port activateCards : (Int, List (List String)) -> Cmd msg
port getText : String -> Cmd msg
port saveObjects : Json.Value -> Cmd msg
port updateCommits : (Json.Value, String) -> Cmd msg




-- MODEL


type alias Model =
  { workingTree : Trees.Model
  , objects : Objects.Model
  , status : Status
  , viewState : ViewState
  }


defaultModel : Model
defaultModel =
  { workingTree = Trees.defaultModel
  , objects = Objects.defaultModel
  , status = Bare
  , viewState =
      { active = "0"
      , activePast = []
      , activeFuture = []
      , descendants = []
      , editing = Just "0"
      }
  }


init : Json.Value -> (Model, Cmd Msg)
init savedState =
  defaultModel ! [focus "0"]
    |> andThen (Activate "0")




-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg ({objects, workingTree, status} as model) =
  let
    vs = model.viewState
  in
  case msg of
    -- === Card Activation ===

    Activate id ->
      let
        activeTree_ = getTree id model.workingTree.tree
        newPast =
          if (id == vs.active) then
            vs.activePast
          else
            vs.active :: vs.activePast |> List.take 40
      in
      case activeTree_ of
        Just activeTree ->
          let
            desc =
              activeTree
                |> getDescendants
                |> List.map .id

            anc =
              getAncestors model.workingTree.tree activeTree []
                |> List.map .id

            flatCols =
              model.workingTree.columns
                |> List.map (\c -> List.map (\g -> List.map .id g) c)
                |> List.map List.concat

            allIds =
              anc
              ++ [id]
              ++ desc
          in
          { model
            | viewState =
                { vs
                  | active = id
                  , activePast = newPast
                  , activeFuture = []
                  , descendants = desc
                }
          }
            ! [ activateCards
                  ( getDepth 0 model.workingTree.tree id
                  , centerlineIds flatCols allIds newPast
                  )
              ]

        Nothing ->
          model ! []

    GoLeft id ->
      let
        targetId =
          getParent id model.workingTree.tree ? defaultTree |> .id
      in
      update (Activate targetId) model

    GoDown id ->
      let
        targetId =
          case getNextInColumn id model.workingTree.tree of
            Nothing -> id
            Just ntree -> ntree.id
      in
      update (Activate targetId) model

    GoUp id ->
      let
        targetId =
          case getPrevInColumn id model.workingTree.tree of
            Nothing -> id
            Just ntree -> ntree.id
      in
      update (Activate targetId) model

    GoRight id ->
      let
        tree_ =
          getTree id model.workingTree.tree

        childrenIds =
          getChildren (tree_ ? defaultTree)
            |> List.map .id

        firstChildId =
          childrenIds
            |> List.head
            |> Maybe.withDefault id

        prevActiveOfChildren =
          vs.activePast
            |> List.filter (\a -> List.member a childrenIds)
            |> List.head
            |> Maybe.withDefault firstChildId
      in
      case tree_ of
        Nothing ->
          model ! []

        Just tree ->
          if List.length childrenIds == 0 then
            model ! []
          else
            update (Activate prevActiveOfChildren) model


    -- === Card Editing  ===

    OpenCard id str ->
      { model
        | viewState = { vs | active = id, editing = Just id }
      }
        ! [focus id]

    GetContentToSave id ->
      model ! [getText id]

    UpdateContent (id, str) ->
      let
        newTree = Trees.update (Trees.Upd id str) model.workingTree
      in
      if newTree.tree /= model.workingTree.tree then
        { model
          | workingTree = newTree
          , viewState = { vs | active = id, editing = Nothing }
        }
          ! []
          |> andThen AttemptCommit
      else
        { model
          | viewState = { vs | active = id, editing = Nothing }
        }
          ! []

    DeleteCard id ->
      let
        filteredActive =
          vs.activePast
            |> List.filter (\a -> a /= id)

        parent_ = getParent id model.workingTree.tree
        prev_ = getPrevInColumn id model.workingTree.tree
        next_ = getNextInColumn id model.workingTree.tree

        nextToActivate =
          case (parent_, prev_, next_) of
            (_, Just prev, _) ->
              prev.id

            (_, Nothing, Just next) ->
              next.id

            (Just parent, Nothing, Nothing) ->
              parent.id

            (Nothing, Nothing, Nothing) ->
              "0"
      in
      { model
        | workingTree = Trees.update (Trees.Del id) model.workingTree
      }
        ! []
        |> andThen (Activate nextToActivate)
        |> andThen AttemptCommit

    CancelCard ->
      { model
        | viewState = { vs | editing = Nothing }
      }
        ! []

    -- === Card Insertion  ===

    Insert pid pos ->
      let
        newId = "node-" ++ (timestamp () |> toString)
        newTree = Tree newId "" (Children [])
      in
      { model
        | workingTree = Trees.update (Trees.Ins newTree pid pos) model.workingTree
      }
        ! []
        |> andThen (OpenCard newId "")
        |> andThen (Activate newId)

    InsertAbove id ->
      let
        idx =
          getIndex id model.workingTree.tree ? 999999

        pid_ =
          getParent id model.workingTree.tree |> Maybe.map .id

        insertMsg =
          case pid_ of
            Just pid ->
              Insert pid idx

            Nothing ->
              NoOp
      in
      update insertMsg model

    InsertBelow id ->
      let
        idx =
          getIndex id model.workingTree.tree ? 999999

        pid_ =
          getParent id model.workingTree.tree |> Maybe.map .id

        insertMsg =
          case pid_ of
            Just pid ->
              Insert pid (idx+1)

            Nothing ->
              NoOp
      in
      update insertMsg model

    InsertChild id ->
      update (Insert id 999999) model

    -- === Card Moving  ===

    Move subtree pid pos ->
      { model
        | workingTree = Trees.update (Trees.Mov subtree pid pos) model.workingTree
      }
        ! []
        |> andThen (Activate subtree.id)
        |> andThen AttemptCommit

    MoveWithin id delta ->
      let
        tree_ =
          getTree id model.workingTree.tree

        pid_ =
          getParent id model.workingTree.tree
            |> Maybe.map .id

        refIdx_ =
          getIndex id model.workingTree.tree
      in
      case (tree_, pid_, refIdx_) of
        (Just tree, Just pid, Just refIdx) ->
          update (Move tree pid (refIdx + delta |> max 0)) model
        _ -> model ! []

    MoveLeft id ->
      let
        tree_ =
          getTree id model.workingTree.tree

        parentId =
          getParent id model.workingTree.tree
            |> Maybe.map .id
            |> Maybe.withDefault "invalid"

        parentIdx_ =
          getIndex parentId model.workingTree.tree

        grandparentId_ =
          getParent parentId model.workingTree.tree
            |> Maybe.map .id
      in
      case (tree_, grandparentId_, parentIdx_) of
        (Just tree, Just gpId, Just refIdx) ->
          update (Move tree gpId (refIdx+1)) model
        _ -> model ! []

    MoveRight id ->
      let
        tree_ =
          getTree id model.workingTree.tree

        prev_ =
          getPrev id model.workingTree.tree
            |> Maybe.map .id
      in
      case (tree_, prev_) of
        (Just tree, Just prev) ->
          update (Move tree prev 999999) model
        _ -> model ! []

    -- === History ===

    Undo ->
      model ! []

    Redo ->
      model ! []

    Fetch ->
      model ! [js ("fetch", null)]

    Push ->
      model ! [js ("push", null)]

    CheckoutCommit commitSha ->
      let
        (newStatus, newTree_, newModel) =
          Objects.update (Objects.Checkout commitSha) objects
      in
      case newTree_ of
        Just newTree ->
          { model
            | workingTree = Trees.setTree newTree model.workingTree
            , status = newStatus
          }
            ! []
            |> andThen (UpdateCommits (objects |> Objects.toValue, commitSha))

        Nothing ->
          model ! []
            |> Debug.log "failed to load commit"

    -- === Ports ===

    ObjectsIn json ->
      let
        (newStatus, newTree_, newObjects) =
          Objects.update (Objects.Merge json workingTree.tree) objects
      in
      case (newStatus, newTree_) of
        (Clean newHead, Just newTree) ->
          { model
            | workingTree = Trees.setTree newTree model.workingTree
            , objects = newObjects
            , status = newStatus
          }
            ! []
            |> andThen (UpdateCommits (newObjects |> Objects.toValue, newHead))

        (MergeConflict oldHead newHead [], Just newTree) ->
          { model
            | workingTree = Trees.setTree newTree model.workingTree
            , objects = newObjects
            , status = newStatus
          }
            ! []
            |> andThen (UpdateCommits (newObjects |> Objects.toValue, newHead))

        (Clean newHead, Nothing) -> -- no changes to Tree
          { model
            | status = newStatus
          }
            ! []
            |> andThen (UpdateCommits (newObjects |> Objects.toValue, newHead))

        _ ->
          model ! []
            |> Debug.log "failed to load data"

    UpdateCommits (json, sha) ->
      model ! [updateCommits (json, sha)]

    AttemptCommit ->
      let
        parents =
          case status of
            Bare -> []
            Clean oldHead -> [oldHead]
            MergeConflict oldHead newHead _ -> [oldHead, newHead]
            -- TODO: Ensure conflicts are resolved before committing.

        (newStatus, _, newObjects) =
          Objects.update (Objects.Commit parents "Jane Doe <jane.doe@gmail.com>" workingTree.tree) model.objects
            |> Debug.log "Commit attempted"
      in
      { model
        | objects = newObjects
        , status = newStatus
      }
        ! [saveObjects (newObjects |> Objects.toValue)]
        |> andThen (UpdateCommits (newObjects |> Objects.toValue, getHead newStatus))

    HandleKey key ->
      case key of
        "mod+x" ->
          let _ = Debug.log "model" model in
          model ! []

        "mod+enter" ->
          editMode model (\id -> GetContentToSave id)

        "enter" ->
          normalMode model (OpenCard vs.active (getContent vs.active model.workingTree.tree))

        "mod+backspace" ->
          normalMode model (DeleteCard vs.active)

        "esc" ->
          update CancelCard model

        "mod+j" ->
          update (InsertBelow vs.active) model

        "mod+down" ->
          update (InsertBelow vs.active) model

        "mod+k" ->
          update (InsertAbove vs.active) model

        "mod+up" ->
          update (InsertAbove vs.active) model

        "mod+l" ->
          update (InsertChild vs.active) model

        "mod+right" ->
          update (InsertChild vs.active) model

        "h" ->
          normalMode model (GoLeft vs.active)

        "left" ->
          normalMode model (GoLeft vs.active)

        "j" ->
          normalMode model (GoDown vs.active)

        "down" ->
          normalMode model (GoDown vs.active)

        "k" ->
          normalMode model (GoUp vs.active)

        "up" ->
          normalMode model (GoUp vs.active)

        "l" ->
          normalMode model (GoRight vs.active)

        "right" ->
          normalMode model (GoRight vs.active)

        "alt+up" ->
          normalMode model (MoveWithin vs.active -1)

        "alt+down" ->
          normalMode model (MoveWithin vs.active 1)

        "alt+left" ->
          normalMode model (MoveLeft vs.active)

        "alt+right" ->
          normalMode model (MoveRight vs.active)

        "alt+shift+up" ->
          normalMode model (MoveWithin vs.active -5)

        "alt+shift+down" ->
          normalMode model (MoveWithin vs.active 5)

        "alt+home" ->
          normalMode model (MoveWithin vs.active -999999)

        "alt+end" ->
          normalMode model (MoveWithin vs.active 999999)

        "mod+z" ->
          normalMode model Undo

        "mod+r" ->
          normalMode model Redo

        _ ->
          model ! []

    _ ->
      model ! []


andThen : Msg -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
andThen msg (model, prevMsg) =
  let
    newStep =
      update msg model
  in
  ( first newStep, Cmd.batch [prevMsg, second newStep] )


onlyIf : Bool -> Msg -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
onlyIf cond msg prevStep =
  if cond then
    prevStep
      |> andThen msg
  else
    prevStep


getHead : Status -> String
getHead status =
  case status of
    Clean head ->
      head

    MergeConflict head _ _ ->
      head

    Bare ->
      ""




-- VIEW


view : Model -> Html Msg
view model =
  div []
    [ div [style [("z-index", "9999"), ("position", "absolute")]]
          [ button [onClick Fetch] [text "fetch"]
          , button [onClick AttemptCommit] [text "commit"]
          , button [onClick Push] [text "push"]
          ]
    , (lazy2 Trees.view model.viewState model.workingTree)
    ]




-- SUBSCRIPTIONS


port objects : (Json.Value -> msg) -> Sub msg
port setHead : (String -> msg) -> Sub msg
port keyboard : (String -> msg) -> Sub msg
port updateContent : ((String, String) -> msg) -> Sub msg


subscriptions : Model -> Sub Msg
subscriptions model =
  Sub.batch
    [ objects ObjectsIn
    , setHead CheckoutCommit
    , keyboard HandleKey
    , updateContent UpdateContent
    ]




-- HELPERS

focus : String -> Cmd Msg
focus id =
  Task.attempt (\_ -> NoOp) (Dom.focus ("card-edit-" ++ id))


run : Msg -> Cmd Msg
run msg =
  Task.attempt (\_ -> msg ) (Task.succeed msg)


editMode : Model -> (String -> Msg) -> (Model, Cmd Msg)
editMode model editing = 
  case model.viewState.editing of
    Nothing ->
      model ! []

    Just uid ->
      update (editing uid) model


normalMode : Model -> Msg -> (Model, Cmd Msg)
normalMode model msg = 
  case model.viewState.editing of
    Nothing ->
      update msg model

    Just _ ->
      model ! []
