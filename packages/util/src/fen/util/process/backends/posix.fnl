;; Wraps fen_process (POSIX spawn/pipes/wait/signal); hosts supply the same surface.
;;
;; Clock primitives deliberately live in fen.util.clock so the agent hot path has no subprocess dependency (#472).

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
