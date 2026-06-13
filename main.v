module main

// main.v — CLI for configuring the 0x1189:0x8890 macro keyboard on Linux.
//
// There is no kernel module to install: the device is a standard USB HID keyboard
// that Linux's usbhid driver already supports. This tool only *reconfigures* the
// macro keys, knobs, media keys, mouse actions and backlight by sending the
// same vendor HID reports the Windows app sends, over /dev/hidraw.
import os

const version = 'v1.0.0'

const usage_text = 'macro_keyboard — configure the macro keyboard (VID 1189 PID 8890)

USAGE:
  macro_keyboard <command> [args]

COMMANDS:
  info                       Find the device and show the detected report id
  layer <1-3>                Switch the active layer
  led <0-2>                  Set backlight mode
  set <slot> <action>        Program one key slot (see SLOTS / ACTIONS)
  apply <file> [--dry-run]   Program many slots from a config file
  dump <slot> <action>       Print the exact reports for an action (no device)
  keys                       List supported key / media / mouse names
  version                    Show the program version
  help                       Show this help

SLOTS (slot number):
  this 3-key + 1-knob unit uses:
    1 2 3      the three keys (left to right)
    13/14/15   knob: turn-left / press / turn-right
  (the protocol also supports 4..12 and a 2nd knob 16/17/18 on larger models)

ACTIONS:
  key:CTRL+C                 a single keystroke (modifiers joined by +)
  key:CTRL+C,CTRL+V          a macro: keystrokes separated by ,  (max 5)
  media:VOL_UP               a media / consumer key
  mouse:LEFT                 a mouse button (LEFT/RIGHT/MIDDLE)
  mouse:WHEEL_UP             mouse wheel up/down
  led:1                      backlight mode (same as the `led` command)

OPTIONS:
  --layer N                  target layer for `set` (default 1)

EXAMPLES:
  macro_keyboard info
  macro_keyboard set 1 key:CTRL+C
  macro_keyboard set 2 key:CTRL+C,CTRL+V --layer 2
  macro_keyboard set 13 media:PREV
  macro_keyboard apply mykeys.conf
'

fn main() {
	args := os.args[1..]
	if args.len == 0 {
		println(usage_text)
		exit(1)
	}
	cmd := args[0]
	match cmd {
		'help', '-h', '--help' {
			println(usage_text)
		}
		'version', '-v', '--version' {
			println('macro_keyboard ${version}')
		}
		'keys' {
			print_key_names()
		}
		'info' {
			cmd_info() or { fail(err) }
		}
		'layer' {
			if args.len < 2 {
				fail_msg('usage: macro_keyboard layer <1-3>')
			}
			cmd_layer(args[1]) or { fail(err) }
		}
		'led' {
			if args.len < 2 {
				fail_msg('usage: macro_keyboard led <0-2>')
			}
			cmd_led(args[1]) or { fail(err) }
		}
		'set' {
			cmd_set(args[1..]) or { fail(err) }
		}
		'apply' {
			if args.len < 2 {
				fail_msg('usage: macro_keyboard apply <file> [--dry-run]')
			}
			cmd_apply(args[1], '--dry-run' in args) or { fail(err) }
		}
		'dump' {
			cmd_dump(args[1..]) or { fail(err) }
		}
		else {
			fail_msg('unknown command: ${cmd}\nrun `macro_keyboard help`')
		}
	}
}

fn open_device() !Device {
	mut dev := find_device()!
	dev.open()!
	return dev
}

fn cmd_info() ! {
	mut dev := find_device()!
	println('Found device : ${vendor_id:04x}:${product_id:04x}')
	dev.open()!
	defer { dev.close() }
	println('Interface    : mi_0${config_interface} (claimed via libusb)')
	println('Report id    : ${dev.report_id}')
	println('Report bytes : ${dev.report_len} (incl. report id)')
	desc := dev.report_descriptor()
	if desc.len > 0 {
		mut hex := []string{}
		for b in desc {
			hex << '${b:02x}'
		}
		println('Report desc  : ${desc.len} bytes')
		println('  ${hex.join(' ')}')
	}
	println('Status       : ready')
}

fn cmd_layer(arg string) ! {
	layer := arg.int()
	if layer < 1 || layer > 3 {
		return error('layer must be 1..3')
	}
	mut dev := open_device()!
	defer { dev.close() }
	dev.switch_layer(u8(layer))!
	println('Switched to layer ${layer}')
}

fn cmd_led(arg string) ! {
	mode := arg.int()
	if mode < 0 || mode > 2 {
		return error('led mode must be 0..2')
	}
	mut dev := open_device()!
	defer { dev.close() }
	dev.program_led(u8(mode))!
	println('Backlight mode set to ${mode}')
}

fn cmd_set(rest []string) ! {
	if rest.len < 2 {
		return error('usage: macro_keyboard set <slot> <action> [--layer N]')
	}
	mut layer := u8(1)
	mut positional := []string{}
	mut i := 0
	for i < rest.len {
		if rest[i] == '--layer' && i + 1 < rest.len {
			layer = u8(rest[i + 1].int())
			i += 2
			continue
		}
		positional << rest[i]
		i++
	}
	if positional.len < 2 {
		return error('usage: macro_keyboard set <slot> <action> [--layer N]')
	}
	slot := u8(positional[0].int())
	action := positional[1]
	mut dev := open_device()!
	defer { dev.close() }
	program_action(dev, slot, layer, action)!
	println('Programmed slot ${slot} (layer ${layer}) -> ${action}')
}

// program_action dispatches an "action string" (e.g. "key:CTRL+C") to the right
// protocol call.
fn program_action(dev &Device, slot u8, layer u8, action string) ! {
	if slot < 1 || slot > 18 {
		return error('slot must be 1..18')
	}
	kind := action.all_before(':').to_lower()
	value := action.all_after(':')
	match kind {
		'key' {
			mut strokes := []Keystroke{}
			for token in value.split(',') {
				strokes << parse_keystroke(token)!
			}
			dev.program_keyboard(slot, layer, strokes)!
		}
		'media', 'consumer' {
			usage := consumer_usages[value.to_upper()] or {
				return error('unknown media key: "${value}"')
			}
			dev.program_consumer(slot, layer, usage)!
		}
		'mouse' {
			dev.program_mouse(slot, layer, parse_mouse(value)!)!
		}
		'led' {
			dev.program_led(u8(value.int()))!
		}
		else {
			return error('unknown action kind "${kind}" (use key:/media:/mouse:/led:)')
		}
	}
}

fn parse_mouse(value string) !MouseAction {
	v := value.to_upper()
	if v == 'WHEEL_UP' || v == 'WHEELUP' {
		return MouseAction{
			wheel: 0x01
		}
	}
	if v == 'WHEEL_DOWN' || v == 'WHEELDOWN' {
		return MouseAction{
			wheel: 0xFF
		}
	}
	btn := mouse_buttons[v] or { return error('unknown mouse action: "${value}"') }
	return MouseAction{
		button: btn
	}
}

// cmd_apply programs slots from a config file. Format (one rule per line):
//   <slot> = <action>
// blank lines and lines starting with # are ignored. Example:
//   1 = key:CTRL+C
//   13 = media:PREV
fn cmd_apply(path string, dry_run bool) ! {
	content := os.read_file(path) or { return error('cannot read ${path}: ${err}') }
	mut dev := if dry_run {
		Device{
			report_id:  3
			report_len: 9
			dry_run:    true
		}
	} else {
		open_device()!
	}
	defer { dev.close() }
	mut count := 0
	for raw in content.split_into_lines() {
		// strip inline/full-line comments (no action token contains '#')
		line := raw.all_before('#').trim_space()
		if line == '' {
			continue
		}
		if !line.contains('=') {
			return error('bad line (need `slot = action`): ${line}')
		}
		slot := u8(line.all_before('=').trim_space().int())
		action := line.all_after('=').trim_space()
		// optional inline layer: "1 = key:CTRL+C @2"
		mut layer := u8(1)
		mut act := action
		if action.contains('@') {
			layer = u8(action.all_after('@').trim_space().int())
			act = action.all_before('@').trim_space()
		}
		program_action(dev, slot, layer, act) or { return error('slot ${slot}: ${err}') }
		println('  slot ${slot} (layer ${layer}) -> ${act}')
		count++
	}
	println('Applied ${count} key binding(s).')
}

// cmd_dump builds and prints the exact reports for an action without any
// hardware, for verifying the wire format. Report id defaults to 3 (the
// layer-capable variant the Windows tool probes first); override with --rid N.
//   macro_keyboard dump <slot> <action> [--layer N] [--rid 3|0|2]
fn cmd_dump(rest []string) ! {
	mut layer := u8(1)
	mut rid := u8(3)
	mut positional := []string{}
	mut i := 0
	for i < rest.len {
		match rest[i] {
			'--layer' {
				layer = u8(rest[i + 1].int())
				i += 2
			}
			'--rid' {
				rid = u8(rest[i + 1].int())
				i += 2
			}
			else {
				positional << rest[i]
				i++
			}
		}
	}
	if positional.len < 2 {
		return error('usage: macro_keyboard dump <slot> <action> [--layer N] [--rid 3|0|2]')
	}
	slot := u8(positional[0].int())
	action := positional[1]
	dev := Device{
		report_id:  rid
		report_len: if rid != 0 { 9 } else { 8 }
		dry_run:    true
	}
	println('dump slot ${slot} layer ${layer} report-id ${rid}: ${action}')
	println('  format: [report_id] d0 d1 d2 d3 d4 d5 d6 d7')
	program_action(dev, slot, layer, action)!
}

fn print_key_names() {
	println('Keyboard keys (use in key:NAME):')
	mut names := []string{}
	for k, _ in keyboard_usages() {
		names << k
	}
	names.sort()
	println('  ' + names.join(' '))
	println('\nModifiers (combine with +):')
	mut mods := []string{}
	for k, _ in modifiers {
		mods << k
	}
	mods.sort()
	println('  ' + mods.join(' '))
	println('\nMedia keys (use in media:NAME):')
	mut media := []string{}
	for k, _ in consumer_usages {
		media << k
	}
	media.sort()
	println('  ' + media.join(' '))
	println('\nMouse (use in mouse:NAME):')
	println('  LEFT RIGHT MIDDLE WHEEL_UP WHEEL_DOWN')
}

@[noreturn]
fn fail(err IError) {
	eprintln('error: ${err.msg()}')
	exit(1)
}

@[noreturn]
fn fail_msg(msg string) {
	eprintln('error: ${msg}')
	exit(1)
}
