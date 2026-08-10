//! C API over the upstream ttfx engine, which Sources/TTFXSaverView.swift
//! links as a static library. No tty and no pacing here: the host owns the
//! clock and pulls one frame per call; frames are the same newline-joined,
//! SGR-colored canvas strings ttfx's own parity dump emits.
//!
//! This is the entire coupling to upstream — everything below goes through
//! ttfx's public API, which is why this project consumes ttfx rather than
//! forking it.
//!
//! Panics are caught at the boundary — unwinding across `extern "C"` would
//! abort the host process, and the host here is the system screensaver.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use ttfx::effects::EffectCommand;
use ttfx::engine::animation::ExistingColorHandling;
use ttfx::engine::canvas::Anchor;
use ttfx::engine::ctx::{Clock, EngineCtx};
use ttfx::engine::effect::Effect;
use ttfx::engine::terminal::TerminalConfig;
use ttfx::utils::rng::Rng;

pub struct TtfxSession {
    effect: Box<dyn Effect>,
    ctx: EngineCtx,
    /// Owns the string returned by the latest next_frame call.
    frame: Option<CString>,
}

/// Comma-joined effect names, e.g. for random selection host-side.
/// Borrowed from a process-lifetime static; never freed.
#[unsafe(no_mangle)]
pub extern "C" fn ttfx_effect_list() -> *const c_char {
    static LIST: std::sync::OnceLock<CString> = std::sync::OnceLock::new();
    LIST.get_or_init(|| {
        use clap::CommandFactory;
        let names: Vec<String> = ttfx::cli::Cli::command()
            .get_subcommands()
            .map(|c| c.get_name().to_string())
            .filter(|n| n != "help")
            .collect();
        CString::new(names.join(",")).expect("effect names contain no NUL")
    })
    .as_ptr()
}

/// Build a session: one effect run over `input_utf8` on a canvas of exactly
/// `canvas_width` x `canvas_height` cells, text centered (the Omarchy
/// screensaver geometry).
///
/// `color_mode` decides what happens to SGR color already in the input, which
/// is what makes ANSI art (as opposed to plain ASCII) worth feeding in:
/// 0 ignores it and lets the effect own every color, 1 keeps it wherever the
/// effect is not itself coloring, 2 always keeps it.
///
/// Returns NULL on any invalid argument.
#[unsafe(no_mangle)]
pub extern "C" fn ttfx_session_new(
    effect_name: *const c_char,
    input_utf8: *const c_char,
    canvas_width: i64,
    canvas_height: i64,
    frame_rate: i64,
    seed: u64,
    color_mode: u8,
) -> *mut TtfxSession {
    if effect_name.is_null() || input_utf8.is_null() || canvas_width < 1 || canvas_height < 1 {
        return std::ptr::null_mut();
    }
    let (Ok(name), Ok(input)) = (
        unsafe { CStr::from_ptr(effect_name) }.to_str(),
        unsafe { CStr::from_ptr(input_utf8) }.to_str(),
    ) else {
        return std::ptr::null_mut();
    };
    if input.trim().is_empty() {
        return std::ptr::null_mut();
    }
    let (name, input) = (name.to_owned(), input.to_owned());
    catch_unwind(move || {
        // Same construction as --random-effect: parse just the effect name so
        // the effect runs with its pure default config.
        let cmd: EffectCommand =
            match clap::Parser::try_parse_from::<_, &str>(["ttfx", &name]) {
                Ok(ttfx::cli::Cli { effect: Some(effect), .. }) => effect,
                _ => return std::ptr::null_mut(),
            };
        let config = TerminalConfig {
            canvas_width,
            canvas_height,
            anchor_canvas: Anchor::C,
            anchor_text: Anchor::C,
            ignore_terminal_dimensions: true,
            frame_rate,
            existing_color_handling: match color_mode {
                1 => ExistingColorHandling::Dynamic,
                2 => ExistingColorHandling::Always,
                _ => ExistingColorHandling::Ignore,
            },
            ..TerminalConfig::default()
        };
        let rng = Rng::seeded(seed);
        let clock = Clock::virtual_with_frame_rate(frame_rate);
        let Ok(mut ctx) = EngineCtx::new(&input, config, rng, clock) else {
            return std::ptr::null_mut();
        };
        let mut effect = cmd.build_effect();
        if effect.build(&mut ctx).is_err() {
            return std::ptr::null_mut();
        }
        Box::into_raw(Box::new(TtfxSession { effect, ctx, frame: None }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Next frame as a NUL-terminated UTF-8 string: canvas rows top-first joined
/// by '\n', colored with SGR truecolor sequences. Returns NULL when the
/// effect is complete (or on panic). The pointer stays valid until the next
/// call on the same session or ttfx_session_free.
///
/// # Safety
/// `s` must be a live pointer from ttfx_session_new.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ttfx_session_next_frame(s: *mut TtfxSession) -> *const c_char {
    if s.is_null() {
        return std::ptr::null();
    }
    let session = unsafe { &mut *s };
    let next = catch_unwind(AssertUnwindSafe(|| {
        session.effect.next_frame(&mut session.ctx)
    }))
    .unwrap_or(None);
    match next {
        Some(frame) => {
            // Frames are terminal text; a NUL can't appear, but don't trust
            // that with UB — fall back to ending the effect.
            session.frame = CString::new(frame).ok();
            session.frame.as_ref().map_or(std::ptr::null(), |f| f.as_ptr())
        }
        None => std::ptr::null(),
    }
}

/// # Safety
/// `s` must be NULL or a live pointer from ttfx_session_new; not usable after.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ttfx_session_free(s: *mut TtfxSession) {
    if !s.is_null() {
        drop(unsafe { Box::from_raw(s) });
    }
}
