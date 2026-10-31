// Deterministic witnesses (quint test) for the lock-reclaim proof model.
module witnesses {
  import lock(FIXES = Set("644")) as F from "./model"

  // Kernel lock: one process takes over the dead owner's lock, the other
  // is refused while it is held.
  run reachTakeoverTest =
    F::init.then(F::tryMkdir(1)).then(F::tryMkdir(2))
      .then(F::readOwner(1)).then(F::writeOwner(1)).then(F::readOwner(2))
      .expect(F::pc.get(1) == "hold" and F::pc.get(2) == "fail" and F::lockInductive)

  // After a release the lock can be taken again by a fresh mkdir.
  run reachReacquireTest =
    F::init.then(F::tryMkdir(1)).then(F::readOwner(1)).then(F::writeOwner(1))
      .then(F::release(1)).then(F::tryMkdir(2)).then(F::writeOwner(2))
      .expect(F::pc.get(2) == "hold" and F::owner == 2 and F::lockInductive)
}
