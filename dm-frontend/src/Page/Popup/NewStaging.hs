module Page.Popup.NewStaging where

import Control.Lens (preview, _1, _2)
import Control.Monad
import Data.Coerce
import Data.Functor
import Data.Generics.Sum
import Data.Map as M
import Data.Monoid
import Data.Text as T (Text, intercalate)
import Prelude as P
import Reflex.Dom as R

import Common.Types
import Common.Validation (isNameValid)
import Frontend.API
import Page.Utils
import Servant.Reflex


newStagingPopup
  :: MonadWidget t m
  => Event t ()
  -> Event t ()
  -> m (Event t ())
newStagingPopup showEv hideEv = sidebar showEv hideEv $ const $ mdo
  divClass "popup__body" $ mdo
    (closeEv', saveEv) <- newStagingPopupHeader enabledDyn
    (deploymentDyn, validDyn) <- newStagingPopupBody respEv
    respEv <- createEndpoint (Right <$> deploymentDyn) saveEv
    sentDyn <- holdDyn False $ leftmost
      [ True <$ saveEv
      , False <$ respEv ]
    let
      successEv =
        fmapMaybe (preview (_Ctor @"Success") <=< commandResponse) respEv
      closeEv = leftmost [ closeEv', successEv ]
      enabledDyn = zipDynWith (&&) (not <$> sentDyn) validDyn
    pure (never, closeEv)

newStagingPopupHeader
  :: MonadWidget t m
  => Dynamic t Bool
  -> m (Event t (), Event t ())
newStagingPopupHeader enabledDyn =
  divClass "popup__head" $ do
    closeEv <- buttonClass "popup__close" "Close popup"
    elClass "h2" "popup__project" $ text "Create new staging"
    saveEv <- divClass "popup__operations" $
      buttonClassEnabled "popup__action button button--save" "Save" enabledDyn
    divClass "popup__menu drop drop--actions" blank
    pure (closeEv, saveEv)


newStagingPopupBody
  :: MonadWidget t m
  => Event t (ReqResult tag CommandResponse)
  -> m (Dynamic t Deployment, Dynamic t Bool)
newStagingPopupBody errEv = divClass "popup__content" $
  divClass "staging" $ mdo
    let
      commandResponseEv = fmapMaybe commandResponse errEv
      appErrEv = R.difference (fmapMaybe reqFailure errEv) commandResponseEv
      nameErrEv = getNameError commandResponseEv nameDyn
      tagErrEv = getTagError commandResponseEv tagDyn
    errorHeader appErrEv
    (nameDyn, nOkDyn) <- dmTextInput "tag" "Name" "Name" Nothing nameErrEv
    (tagDyn, tOkDyn) <- dmTextInput "tag" "Tag" "Tag" Nothing tagErrEv
    appVarsDyn <- envVarsInput "App overrides"
    stagingVarsDyn <- envVarsInput "Staging overrides"
    validDyn <- holdDyn False $ updated $ zipDynWith (&&) nOkDyn tOkDyn
    pure $ (Deployment
      <$> (DeploymentName <$> nameDyn)
      <*> (DeploymentTag <$> tagDyn)
      <*> (coerce <$> appVarsDyn)
      <*> (coerce <$> stagingVarsDyn), validDyn)
  where
    getNameError crEv nameDyn = let
      nameErrEv' = fmapMaybe (preview (_Ctor @"ValidationError" . _1 )) crEv
      isNameValidDyn = isNameValid . DeploymentName <$> nameDyn
      badNameText = "Staging name length should be longer than 2 characters \
      \and under 17 characters and begin with a letter."
      badNameEv = badNameText <$ (ffilter not $ updated isNameValidDyn)
      nameErrEv = ffilter (/= "") $ T.intercalate ". " <$> nameErrEv'
      in leftmost [nameErrEv, badNameEv]
    getTagError crEv tagDyn = let
      tagErrEv' = fmapMaybe (preview (_Ctor @"ValidationError" . _2 )) crEv
      tagErrEv = ffilter (/= "") $ T.intercalate ". " <$> tagErrEv'
      badTagText = "Tag should not be empty"
      badNameEv = badTagText <$ (ffilter (== "") $ updated tagDyn)
      in leftmost [tagErrEv, badNameEv]

errorHeader :: MonadWidget t m => Event t Text -> m ()
errorHeader appErrEv = do
  widgetHold_ blank $ appErrEv <&> \appErr -> do
    divClass "staging__output notification notification--danger" $ do
      el "b" $ text "App error: "
      text appErr

envVarsInput :: MonadWidget t m => Text -> m (Dynamic t [Override])
envVarsInput headerText = do
  elClass "section" "staging__section" $ do
    elClass "h3" "staging__sub-heading" $ text headerText
    elClass "div" "staging__widget" $
      elClass "div" "overrides" $ mdo
        let
          emptyVar = Override "" "" Public
          addEv = clickEv $> Endo (\envs -> P.length envs =: emptyVar <> envs)
        envsDyn <- foldDyn appEndo mempty $ leftmost [ addEv, updEv ]
        (_, updEv)  <- runEventWriterT $ listWithKey envsDyn envVarInput
        let addDisabledDyn = all ( (/= "") . overrideKey ) . elems <$> envsDyn
        clickEv <- buttonClassEnabled'
          "overrides__add dash dash--add" "Add an override" addDisabledDyn
          "dash--disabled"
        pure $ elems <$> envsDyn

envVarInput
  :: (EventWriter t (Endo (Map Int Override)) m, MonadWidget t m)
  => Int
  -> Dynamic t Override
  -> m ()
envVarInput ix _ = do
  divClass "overrides__item" $ do
    (keyDyn, _) <- dmTextInput' "overrides__key" "key" Nothing never
    (valDyn, _) <- dmTextInput' "overrides__value" "value" Nothing never
    closeEv <- buttonClass "overrides__delete spot spot--cancel" "Delete"
    let
      envEv = updated $ zipDynWith (\k v -> Override k v Public) keyDyn valDyn
      deleteEv = Endo (M.delete ix) <$ closeEv
      updEv = Endo . flip update ix . const . Just <$> envEv
    tellEvent $ leftmost [deleteEv, updEv]

