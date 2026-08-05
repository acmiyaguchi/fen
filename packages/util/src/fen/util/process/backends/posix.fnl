;; Default (POSIX) subprocess backend for fen.util.process.
;;
;; Wraps the project-owned fen_process native module, which owns the POSIX
;; subprocess surface: nonblocking pipe reads, spawn/spawn_shell into a fresh
;; session, wait_pid polling, and process-group signalling. The public module
;; (fen.util.process) builds its cooperative drain/timeout state machine on top
;; of these primitives.
;;
;; This is the seam's default backend (see fen.util.process.backend). Keeping
;; the fen_process behavior here means the injectable seam changes nothing about
;; default CLI behavior. A host without a POSIX subprocess surface (WASM, a
;; sandboxed runtime) supplies its own backend exposing the same surface:
;; fileno/set_nonblock/read/close_fd, spawn/spawn_shell/wait_pid/
;; kill_process_group, setenv, and the EAGAIN/EWOULDBLOCK/SIGTERM/SIGKILL
;; constants.
;;
;; The clock primitives (monotonic_ms/sleep_ms) deliberately do NOT live here;
;; they route through fen.util.clock so the agent hot path has no subprocess
;; dependency (#472).

(local native (require :fen_process))

{:fileno native.fileno
 :set_nonblock native.set_nonblock
 :read native.read
 :close_fd native.close_fd
 :spawn native.spawn
 :spawn_shell native.spawn_shell
 :wait_pid native.wait_pid
 :kill_process_group native.kill_process_group
 :setenv native.setenv
 :EAGAIN native.EAGAIN
 :EWOULDBLOCK native.EWOULDBLOCK
 :SIGTERM native.SIGTERM
 :SIGKILL native.SIGKILL}
