// Deterministic witnesses (quint test) for the lock-reclaim proof model.
module witnesses {
  import lock(FIXES = Set()) as C from "./model"
  import lock(FIXES = Set("644")) as F from "./model"

  // #644: both processes read the dead owner and pass the re-read before
  // either removes anything; 1 reclaims and holds the lock, then 2 removes
  // the (empty) owner file, rmdirs the empty directory and mkdirs too.
  run w644DoubleReclaimTest =
    C::init.then(C::tryMkdir(1)).then(C::tryMkdir(2))
      .then(C::readOwner(1)).then(C::readOwner(2))
      .then(C::recheck(1)).then(C::recheck(2))
      .then(C::rmOwner(1)).then(C::rmdir(1)).then(C::mk(1))
      .then(C::rmOwner(2)).then(C::rmdir(2)).then(C::mk(2))
      .expect(C::pc.get(1) == "own" and C::pc.get(2) == "own" and not(C::lockMutex))

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
