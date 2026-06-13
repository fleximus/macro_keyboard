module main

// keycodes.v — human-readable names for HID usages, matching the codes the
// Windows tool wrote (standard USB HID Keyboard/Keypad usage page, the
// Keyboard modifier bitmask, and the Consumer page for media keys).

// Keyboard modifier bits (HID modifier byte), as set in FunKey.cs / BasicKeys.cs.
const modifiers = {
	'CTRL':   u8(0x01)
	'LCTRL':  u8(0x01)
	'SHIFT':  u8(0x02)
	'LSHIFT': u8(0x02)
	'ALT':    u8(0x04)
	'LALT':   u8(0x04)
	'WIN':    u8(0x08)
	'GUI':    u8(0x08)
	'LWIN':   u8(0x08)
	'LGUI':   u8(0x08)
	'RCTRL':  u8(0x10)
	'RSHIFT': u8(0x20)
	'RALT':   u8(0x40)
	'ALTGR':  u8(0x40)
	'RWIN':   u8(0x80)
	'RGUI':   u8(0x80)
}

// keyboard_usages: name -> HID Keyboard/Keypad usage id (page 0x07).
fn keyboard_usages() map[string]u8 {
	mut m := map[string]u8{}
	// Letters A..Z = 0x04..0x1D
	letters := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
	for i, c in letters {
		m['${c:c}'] = u8(0x04 + i)
	}
	// Digits 1..9,0 = 0x1E..0x27
	digits := '1234567890'
	for i, c in digits {
		m['${c:c}'] = u8(0x1E + i)
	}
	// Function keys F1..F12 = 0x3A..0x45
	for i in 0 .. 12 {
		m['F${i + 1}'] = u8(0x3A + i)
	}
	// F13..F24 = 0x68..0x73 — exist in HID but on no physical keyboard, so they
	// make conflict-free triggers to bind in your desktop for launching apps.
	for i in 0 .. 12 {
		m['F${i + 13}'] = u8(0x68 + i)
	}
	named := {
		'ENTER':       u8(0x28)
		'RETURN':      u8(0x28)
		'ESC':         u8(0x29)
		'ESCAPE':      u8(0x29)
		'BACKSPACE':   u8(0x2A)
		'BKSP':        u8(0x2A)
		'TAB':         u8(0x2B)
		'SPACE':       u8(0x2C)
		'MINUS':       u8(0x2D)
		'EQUAL':       u8(0x2E)
		'LBRACKET':    u8(0x2F)
		'RBRACKET':    u8(0x30)
		'BACKSLASH':   u8(0x31)
		'SEMICOLON':   u8(0x33)
		'QUOTE':       u8(0x34)
		'GRAVE':       u8(0x35)
		'TILDE':       u8(0x35)
		'COMMA':       u8(0x36)
		'PERIOD':      u8(0x37)
		'DOT':         u8(0x37)
		'SLASH':       u8(0x38)
		'CAPSLOCK':    u8(0x39)
		'PRINTSCREEN': u8(0x46)
		'PRTSC':       u8(0x46)
		'SCROLLLOCK':  u8(0x47)
		'PAUSE':       u8(0x48)
		'INSERT':      u8(0x49)
		'INS':         u8(0x49)
		'HOME':        u8(0x4A)
		'PAGEUP':      u8(0x4B)
		'PGUP':        u8(0x4B)
		'DELETE':      u8(0x4C)
		'DEL':         u8(0x4C)
		'END':         u8(0x4D)
		'PAGEDOWN':    u8(0x4E)
		'PGDN':        u8(0x4E)
		'RIGHT':       u8(0x4F)
		'LEFT':        u8(0x50)
		'DOWN':        u8(0x51)
		'UP':          u8(0x52)
		'NUMLOCK':     u8(0x53)
		'MENU':        u8(0x65)
		'APP':         u8(0x65)
	}
	for k, v in named {
		m[k] = v
	}
	return m
}

// consumer_usages: name -> 16-bit Consumer page (0x0C) usage, for media keys.
const consumer_usages = {
	'PLAY':       u16(0x00CD)
	'PLAYPAUSE':  u16(0x00CD)
	'PAUSE':      u16(0x00CD)
	'STOP':       u16(0x00B7)
	'NEXT':       u16(0x00B5)
	'NEXTSONG':   u16(0x00B5)
	'PREV':       u16(0x00B6)
	'PREVSONG':   u16(0x00B6)
	'MUTE':       u16(0x00E2)
	'VOLUP':      u16(0x00E9)
	'VOL_UP':     u16(0x00E9)
	'VOLUMEUP':   u16(0x00E9)
	'VOLDOWN':    u16(0x00EA)
	'VOL_DOWN':   u16(0x00EA)
	'VOLUMEDOWN': u16(0x00EA)
	'BRIGHTUP':   u16(0x006F)
	'BRIGHTDOWN': u16(0x0070)
	'CALC':       u16(0x0192)
	'EMAIL':      u16(0x018A)
	'HOMEPAGE':   u16(0x0223)
	'BROWSER':    u16(0x0223)
	'SEARCH':     u16(0x0221)
	'BACK':       u16(0x0224)
	'FORWARD':    u16(0x0225)
}

// mouse_buttons: name -> button bitmask / wheel for type-3 mouse actions.
const mouse_buttons = {
	'LEFT':   u8(0x01)
	'RIGHT':  u8(0x02)
	'MIDDLE': u8(0x04)
	'CENTRE': u8(0x04)
	'CENTER': u8(0x04)
}

// parse_keystroke parses one keystroke token like "CTRL+SHIFT+C" into a
// Keystroke (modifiers OR'd, final token = the key). A bare modifier ("CTRL")
// yields a modifier-only keystroke.
fn parse_keystroke(token string) !Keystroke {
	parts := token.to_upper().split('+')
	usages := keyboard_usages()
	mut mod := u8(0)
	mut key := u8(0)
	for p in parts {
		t := p.trim_space()
		if t == '' {
			continue
		}
		if m := modifiers[t] {
			mod |= m
			continue
		}
		if k := usages[t] {
			key = k
			continue
		}
		return error('unknown key name: "${t}"')
	}
	return Keystroke{
		modifier: mod
		keycode:  key
	}
}
