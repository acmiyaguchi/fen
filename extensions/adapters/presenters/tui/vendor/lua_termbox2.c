/* Minimal Lua 5.4 binding for termbox2.
 *
 * Exports just the surface fen's TUI uses: init/shutdown/dims/
 * clear/present/set_cell/print/cursor/input-output-mode/poll-peek event,
 * plus the TB_* constants.
 *
 * No published lua-termbox2 rock exists; this shim is vendored to keep the
 * dependency surface bounded. Update termbox2.h independently. */

#define TB_IMPL
#include "termbox2.h"

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>

/* ---------- signal teardown ---------- */

/*
 * termbox2 puts the tty into raw mode + alt-screen + hidden-cursor + SGR mouse
 * reporting, and only tb_shutdown undoes it. termbox installs a handler for
 * SIGWINCH only, so an async terminating signal (SIGHUP on ssh/terminal
 * disconnect, SIGTERM from a session manager, an external SIGINT) kills the
 * process before Lua can unwind, leaving the recovered shell in raw mode with
 * mouse reporting still on (#143).
 *
 * Install a best-effort handler for those signals that restores the terminal
 * then re-raises with the default disposition so the exit status (and any
 * parent's WIFSIGNALED) still reflects the real signal. tb_shutdown is not
 * strictly async-signal-safe (it free()s and tcsetattr()s), but a best-effort
 * restore beats a wedged terminal; SIGKILL/OOM remain unrecoverable by design.
 */
static const int FEN_TERM_SIGNALS[] = { SIGHUP, SIGINT, SIGTERM };

static void fen_term_signal(int signum) {
    tb_shutdown();
    /* Restore the default disposition and re-raise. The delivered signal is
     * blocked for the duration of this handler, so there's no re-entry. */
    signal(signum, SIG_DFL);
    raise(signum);
}

static void fen_install_term_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = fen_term_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    for (size_t i = 0; i < sizeof FEN_TERM_SIGNALS / sizeof FEN_TERM_SIGNALS[0]; i++)
        sigaction(FEN_TERM_SIGNALS[i], &sa, NULL);
}

static void fen_restore_term_handlers(void) {
    for (size_t i = 0; i < sizeof FEN_TERM_SIGNALS / sizeof FEN_TERM_SIGNALS[0]; i++)
        signal(FEN_TERM_SIGNALS[i], SIG_DFL);
}

/* ---------- helpers ---------- */

static int push_tb_result(lua_State *L, int rc) {
    if (rc < 0) {
        lua_pushnil(L);
        lua_pushstring(L, tb_strerror(rc));
        lua_pushinteger(L, rc);
        return 3;
    }
    lua_pushinteger(L, rc);
    return 1;
}

/* ---------- bracketed paste escape extraction ---------- */

#define FEN_KEY_PASTE_BEGIN tb_key_i(100)
#define FEN_KEY_PASTE_END   tb_key_i(101)

static int fen_extract_paste(struct tb_event *ev, size_t *consumed) {
    const char *buf = global.in.buf;
    size_t len = global.in.len;

    if (len < 2 || buf[0] != '\x1b' || buf[1] != '[') return TB_ERR;

    if (len < 6) {
        if ((len <= 2 && memcmp(buf, "\x1b[", len) == 0) ||
            (len <= 5 && memcmp(buf, "\x1b[200~", len) == 0) ||
            (len <= 5 && memcmp(buf, "\x1b[201~", len) == 0)) {
            return TB_ERR_NEED_MORE;
        }
        return TB_ERR;
    }

    if (memcmp(buf, "\x1b[200~", 6) == 0) {
        ev->type = TB_EVENT_KEY;
        ev->key = FEN_KEY_PASTE_BEGIN;
        ev->ch = 0;
        ev->mod = 0;
        *consumed = 6;
        return TB_OK;
    }

    if (memcmp(buf, "\x1b[201~", 6) == 0) {
        ev->type = TB_EVENT_KEY;
        ev->key = FEN_KEY_PASTE_END;
        ev->ch = 0;
        ev->mod = 0;
        *consumed = 6;
        return TB_OK;
    }

    return TB_ERR;
}

/* ---------- API wrappers ---------- */

static int l_init(lua_State *L) {
    int rc = tb_init();
    if (rc >= 0) {
        tb_set_func(TB_FUNC_EXTRACT_PRE, fen_extract_paste);
        fen_install_term_handlers();
    }
    return push_tb_result(L, rc);
}

static int l_shutdown(lua_State *L) {
    int rc = tb_shutdown();
    /* The terminal is restored; drop our handlers so a later signal takes its
     * default action (e.g. while suspended between shutdown and re-init). */
    fen_restore_term_handlers();
    return push_tb_result(L, rc);
}

/* Ctrl-Z job-control suspend (#124): raw mode disables ISIG, so Ctrl-Z never
 * becomes SIGTSTP at the tty — fen receives it as a key. The presenter restores
 * the terminal, then calls this to stop itself with SIGTSTP's default
 * disposition. Execution resumes here on fg/SIGCONT, after which the presenter
 * re-inits termbox and repaints. We never install a SIGTSTP handler, so the
 * default stop action applies. */
static int l_raise_sigtstp(lua_State *L) {
    (void)L;
    raise(SIGTSTP);
    return 0;
}

static int l_width(lua_State *L) {
    lua_pushinteger(L, tb_width());
    return 1;
}

static int l_height(lua_State *L) {
    lua_pushinteger(L, tb_height());
    return 1;
}

static int l_clear(lua_State *L) {
    return push_tb_result(L, tb_clear());
}

static int l_present(lua_State *L) {
    return push_tb_result(L, tb_present());
}

static int l_set_cursor(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    return push_tb_result(L, tb_set_cursor(x, y));
}

static int l_hide_cursor(lua_State *L) {
    return push_tb_result(L, tb_hide_cursor());
}

static int l_set_cell(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    /* arg 3: either an integer codepoint or a 1-character UTF-8 string */
    uint32_t ch;
    if (lua_type(L, 3) == LUA_TSTRING) {
        size_t slen;
        const char *s = lua_tolstring(L, 3, &slen);
        if (slen == 0) {
            ch = ' ';
        } else {
            int n = tb_utf8_char_to_unicode(&ch, s);
            if (n <= 0) ch = (unsigned char)s[0];
        }
    } else {
        ch = (uint32_t)luaL_checkinteger(L, 3);
    }
    uintattr_t fg = (uintattr_t)luaL_optinteger(L, 4, 0);
    uintattr_t bg = (uintattr_t)luaL_optinteger(L, 5, 0);
    return push_tb_result(L, tb_set_cell(x, y, ch, fg, bg));
}

static int l_print(lua_State *L) {
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    uintattr_t fg = (uintattr_t)luaL_optinteger(L, 3, 0);
    uintattr_t bg = (uintattr_t)luaL_optinteger(L, 4, 0);
    const char *s = luaL_checkstring(L, 5);
    return push_tb_result(L, tb_print(x, y, fg, bg, s));
}

static int l_set_input_mode(lua_State *L) {
    int mode = (int)luaL_optinteger(L, 1, TB_INPUT_CURRENT);
    return push_tb_result(L, tb_set_input_mode(mode));
}

static int l_set_output_mode(lua_State *L) {
    int mode = (int)luaL_optinteger(L, 1, TB_OUTPUT_CURRENT);
    return push_tb_result(L, tb_set_output_mode(mode));
}

static void push_event(lua_State *L, const struct tb_event *ev) {
    lua_createtable(L, 0, 8);
    lua_pushinteger(L, ev->type); lua_setfield(L, -2, "type");
    lua_pushinteger(L, ev->mod);  lua_setfield(L, -2, "mod");
    lua_pushinteger(L, ev->key);  lua_setfield(L, -2, "key");
    lua_pushinteger(L, ev->ch);   lua_setfield(L, -2, "ch");
    lua_pushinteger(L, ev->w);    lua_setfield(L, -2, "w");
    lua_pushinteger(L, ev->h);    lua_setfield(L, -2, "h");
    lua_pushinteger(L, ev->x);    lua_setfield(L, -2, "x");
    lua_pushinteger(L, ev->y);    lua_setfield(L, -2, "y");
    /* Convenience: if ch != 0, expose as utf8 string too. */
    if (ev->ch != 0) {
        char buf[8];
        int n = tb_utf8_unicode_to_char(buf, ev->ch);
        if (n > 0) {
            lua_pushlstring(L, buf, (size_t)n);
            lua_setfield(L, -2, "utf8");
        }
    }
}

static int retryable_poll_interrupt(int rc) {
    /*
     * A signal (SIGWINCH on resize, SIGCONT/SIGTSTP on job control,
     * SIGCHLD from a finished tool subprocess) can interrupt either the
     * select(2) (-> TB_ERR_POLL) or the tty read(2) (-> TB_ERR_READ)
     * inside termbox's wait_event, with errno EINTR/EAGAIN. Both are
     * transient: the next call re-selects and either drains the resize
     * pipe or returns the pending input. Only TB_ERR_POLL was retried
     * before, so a signal landing on the read() crashed the TUI (#132).
     */
    if (rc != TB_ERR_POLL && rc != TB_ERR_READ) return 0;
    int e = tb_last_errno();
    return e == EINTR || e == EAGAIN;
}

static int l_poll_event(lua_State *L) {
    struct tb_event ev;
    int rc;

    /* Retry transient signal-interrupted polls/reads; see
     * retryable_poll_interrupt. */
    do {
        rc = tb_poll_event(&ev);
    } while (retryable_poll_interrupt(rc));

    if (rc < 0) {
        lua_pushnil(L);
        lua_pushstring(L, tb_strerror(rc));
        lua_pushinteger(L, rc);
        return 3;
    }
    push_event(L, &ev);
    return 1;
}

static int l_peek_event(lua_State *L) {
    int timeout_ms = (int)luaL_optinteger(L, 1, 0);
    struct tb_event ev;
    int rc;

    do {
        rc = tb_peek_event(&ev, timeout_ms);
    } while (retryable_poll_interrupt(rc));

    if (rc < 0) {
        lua_pushnil(L);
        lua_pushstring(L, tb_strerror(rc));
        lua_pushinteger(L, rc);
        return 3;
    }
    push_event(L, &ev);
    return 1;
}

static int l_version(lua_State *L) {
    lua_pushstring(L, tb_version());
    return 1;
}

/* ---------- module table ---------- */

static const luaL_Reg lib[] = {
    {"init",            l_init},
    {"shutdown",        l_shutdown},
    {"width",           l_width},
    {"height",          l_height},
    {"clear",           l_clear},
    {"present",         l_present},
    {"set_cursor",      l_set_cursor},
    {"hide_cursor",     l_hide_cursor},
    {"set_cell",        l_set_cell},
    {"print",           l_print},
    {"set_input_mode",  l_set_input_mode},
    {"set_output_mode", l_set_output_mode},
    {"poll_event",      l_poll_event},
    {"peek_event",      l_peek_event},
    {"raise_sigtstp",   l_raise_sigtstp},
    {"version",         l_version},
    {NULL, NULL},
};

#define SETI(name, val) do { \
    lua_pushinteger(L, (lua_Integer)(val)); \
    lua_setfield(L, -2, name); \
} while (0)

int luaopen_termbox2(lua_State *L) {
    luaL_newlib(L, lib);

    /* event types */
    SETI("EVENT_KEY",    TB_EVENT_KEY);
    SETI("EVENT_RESIZE", TB_EVENT_RESIZE);
    SETI("EVENT_MOUSE",  TB_EVENT_MOUSE);

    /* peek_event returns this when the timeout elapsed with no input */
    SETI("ERR_NO_EVENT", TB_ERR_NO_EVENT);

    /* modifier flags */
    SETI("MOD_ALT",    TB_MOD_ALT);
    SETI("MOD_CTRL",   TB_MOD_CTRL);
    SETI("MOD_SHIFT",  TB_MOD_SHIFT);
    SETI("MOD_MOTION", TB_MOD_MOTION);

    /* input/output modes */
    SETI("INPUT_CURRENT", TB_INPUT_CURRENT);
    SETI("INPUT_ESC",     TB_INPUT_ESC);
    SETI("INPUT_ALT",     TB_INPUT_ALT);
    SETI("INPUT_MOUSE",   TB_INPUT_MOUSE);

    SETI("OUTPUT_CURRENT",   TB_OUTPUT_CURRENT);
    SETI("OUTPUT_NORMAL",    TB_OUTPUT_NORMAL);
    SETI("OUTPUT_256",       TB_OUTPUT_256);
    SETI("OUTPUT_216",       TB_OUTPUT_216);
    SETI("OUTPUT_GRAYSCALE", TB_OUTPUT_GRAYSCALE);
    /* TB_OUTPUT_TRUECOLOR is gated by TB_OPT_ATTR_W >= 32; default attr
     * width is 16, so we don't expose truecolor here. */

    /* colors (16-color set; valid in OUTPUT_NORMAL) */
    SETI("DEFAULT", TB_DEFAULT);
    SETI("BLACK",   TB_BLACK);
    SETI("RED",     TB_RED);
    SETI("GREEN",   TB_GREEN);
    SETI("YELLOW",  TB_YELLOW);
    SETI("BLUE",    TB_BLUE);
    SETI("MAGENTA", TB_MAGENTA);
    SETI("CYAN",    TB_CYAN);
    SETI("WHITE",   TB_WHITE);

    /* attributes (OR with color in OUTPUT_NORMAL mode) */
    SETI("BOLD",      TB_BOLD);
    SETI("UNDERLINE", TB_UNDERLINE);
    SETI("REVERSE",   TB_REVERSE);
    SETI("ITALIC",    TB_ITALIC);
    SETI("DIM",       TB_DIM);

    /* keys we care about (subset) */
    SETI("KEY_CTRL_A",     TB_KEY_CTRL_A);
    SETI("KEY_CTRL_B",     TB_KEY_CTRL_B);
    SETI("KEY_CTRL_C",     TB_KEY_CTRL_C);
    SETI("KEY_CTRL_D",     TB_KEY_CTRL_D);
    SETI("KEY_CTRL_E",     TB_KEY_CTRL_E);
    SETI("KEY_CTRL_F",     TB_KEY_CTRL_F);
    SETI("KEY_CTRL_J",     TB_KEY_CTRL_J);
    SETI("KEY_CTRL_K",     TB_KEY_CTRL_K);
    SETI("KEY_CTRL_L",     TB_KEY_CTRL_L);
    SETI("KEY_CTRL_N",     TB_KEY_CTRL_N);
    SETI("KEY_CTRL_P",     TB_KEY_CTRL_P);
    SETI("KEY_CTRL_U",     TB_KEY_CTRL_U);
    SETI("KEY_CTRL_W",     TB_KEY_CTRL_W);
    SETI("KEY_CTRL_Z",     TB_KEY_CTRL_Z);
    SETI("KEY_BACKSPACE",  TB_KEY_BACKSPACE);
    SETI("KEY_BACKSPACE2", TB_KEY_BACKSPACE2);
    SETI("KEY_TAB",        TB_KEY_TAB);
    SETI("KEY_ENTER",      TB_KEY_ENTER);
    SETI("KEY_ESC",        TB_KEY_ESC);
    SETI("KEY_SPACE",      TB_KEY_SPACE);
    SETI("KEY_HOME",       TB_KEY_HOME);
    SETI("KEY_END",        TB_KEY_END);
    SETI("KEY_PGUP",       TB_KEY_PGUP);
    SETI("KEY_PGDN",       TB_KEY_PGDN);
    SETI("KEY_INSERT",     TB_KEY_INSERT);
    SETI("KEY_DELETE",     TB_KEY_DELETE);
    SETI("KEY_ARROW_UP",    TB_KEY_ARROW_UP);
    SETI("KEY_ARROW_DOWN",  TB_KEY_ARROW_DOWN);
    SETI("KEY_ARROW_LEFT",  TB_KEY_ARROW_LEFT);
    SETI("KEY_ARROW_RIGHT", TB_KEY_ARROW_RIGHT);
    SETI("KEY_PASTE_BEGIN", FEN_KEY_PASTE_BEGIN);
    SETI("KEY_PASTE_END",   FEN_KEY_PASTE_END);

    /* mouse: surfaced in TB_EVENT_MOUSE events as `key` */
    SETI("KEY_MOUSE_LEFT",       TB_KEY_MOUSE_LEFT);
    SETI("KEY_MOUSE_RIGHT",      TB_KEY_MOUSE_RIGHT);
    SETI("KEY_MOUSE_MIDDLE",     TB_KEY_MOUSE_MIDDLE);
    SETI("KEY_MOUSE_RELEASE",    TB_KEY_MOUSE_RELEASE);
    SETI("KEY_MOUSE_WHEEL_UP",   TB_KEY_MOUSE_WHEEL_UP);
    SETI("KEY_MOUSE_WHEEL_DOWN", TB_KEY_MOUSE_WHEEL_DOWN);

    return 1;
}
