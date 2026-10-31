// Reachability for the drafts proof model: drafts really move between tabs.
module witnesses {
  import drafts as D from "./model"

  run reachDraftSurvivesRoundTripTest =
    D::init.then(D::setDraft(1)).then(D::openSide).then(D::setDraft(1)).then(D::switchTo("main"))
      .then(D::switchTo("side")).then(D::closeTab)
      .expect(D::view == 1 and not(D::sideOpen) and D::draftsInductive)

  run reachSubTabDraftTest =
    D::init.then(D::subStart).then(D::switchTo("sub")).then(D::setDraft(1)).then(D::switchTo("main"))
      .expect(D::recSub == 1 and D::draftsInductive)
}
