module main

// protocol.v — the macro keyboard's configuration wire protocol, ported
// faithfully from Windows/HIDTester/FormMain.cs (Download_Click et al.).
//
// Every action programs one key slot (1..18) and is committed to the device's
// flash with a trailing save command. Each report is [report_id] + 8 data
// bytes; this file builds those 8 data bytes.
//
//   data[0] = key slot number (1..18)
//   data[1] = (layer << 4) | type     (low nibble = type, high nibble = layer)
//   data[2..] = type-specific payload
//
// Key types (low nibble of data[1]):
//   1 = keyboard macro   (sequence of modifier+keycode keystrokes)
//   2 = consumer / media (16-bit Consumer-page usage)
//   3 = mouse            (button, x, y, wheel, modifier)
//   8 = LED backlight    (mode byte)
//
// Key slots: 1..12 = keys, 13/14/15 = knob1 left/press/right,
//            16/17/18 = knob2 left/press/right.

const key_type_keyboard = u8(1)
const key_type_consumer = u8(2)
const key_type_mouse = u8(3)
const key_type_led = u8(8)

// A single keystroke in a keyboard macro: a HID modifier bitmask plus a HID
// keyboard usage id (0 = none).
pub struct Keystroke {
pub:
	modifier u8
	keycode  u8
}

// build_type_byte combines layer and type exactly as Download_Click does:
// when report_id == 0 the firmware ignores layers (data[1] = type only);
// otherwise data[1] = (layer << 4) | type.
fn (d &Device) build_type_byte(layer u8, ktype u8) u8 {
	if d.report_id == 0 {
		return ktype & 0x0F
	}
	mut b := layer
	if b == 0 {
		b = 1
	}
	return u8(b << 4) | ktype
}

// switch_layer sends the [0xA1, layer] command. The Windows tool issues this
// before programming whenever a non-zero report id (layer-capable firmware) is
// in use.
pub fn (d &Device) switch_layer(layer u8) ! {
	mut l := layer
	if l == 0 {
		l = 1
	}
	d.send([u8(0xA1), l])!
}

// save_flash commits the previously written key data to flash ([0xAA, 0xAA]).
fn (d &Device) save_flash() ! {
	d.send([u8(0xAA), 0xAA])!
}

// save_flash_led commits LED settings to flash ([0xAA, 0xA1]).
fn (d &Device) save_flash_led() ! {
	d.send([u8(0xAA), 0xA1])!
}

// program_keyboard programs a key slot with a keyboard macro: a sequence of up
// to 5 keystrokes. Mirrors the type-1 branch of Download_Click, which sends one
// report per keystroke (index 0 carries the leading modifier with no key).
pub fn (d &Device) program_keyboard(key u8, layer u8, strokes []Keystroke) ! {
	if strokes.len == 0 || strokes.len > 5 {
		return error('keyboard macro needs 1..5 keystrokes, got ${strokes.len}')
	}
	if d.report_id != 0 {
		d.switch_layer(layer)!
	}
	type_byte := d.build_type_byte(layer, key_type_keyboard)
	group_count := u8(strokes.len)
	// b ranges 0..group_count inclusive: index 0 is the modifier header, indices
	// 1..N carry (modifier, keycode) for each keystroke.
	for b in u8(0) .. group_count + 1 {
		mut data := []u8{len: 8}
		data[0] = key
		data[1] = type_byte
		data[2] = group_count
		data[3] = b
		if b == 0 {
			data[4] = strokes[0].modifier
			data[5] = 0
		} else {
			data[4] = strokes[b - 1].modifier
			data[5] = strokes[b - 1].keycode
		}
		d.send(data)!
	}
	d.save_flash()!
}

// program_consumer programs a 16-bit Consumer-page usage (media key).
// Type-2 branch: data[2] = usage low byte, data[3] = usage high byte.
pub fn (d &Device) program_consumer(key u8, layer u8, usage u16) ! {
	if d.report_id != 0 {
		d.switch_layer(layer)!
	}
	mut data := []u8{len: 8}
	data[0] = key
	data[1] = d.build_type_byte(layer, key_type_consumer)
	data[2] = u8(usage & 0xFF)
	data[3] = u8(usage >> 8)
	d.send(data)!
	d.save_flash()!
}

// MouseAction describes a type-3 mouse event.
pub struct MouseAction {
pub:
	button   u8 // bit0=left, bit1=right, bit2=middle
	x        u8 // relative X (signed as u8)
	y        u8 // relative Y
	wheel    u8 // wheel delta (1 = up, 0xFF = down)
	modifier u8 // optional keyboard modifier held with the click
}

// program_mouse programs a mouse action. Type-3 branch:
// data[2..6] = button, x, y, wheel, modifier.
pub fn (d &Device) program_mouse(key u8, layer u8, m MouseAction) ! {
	if d.report_id != 0 {
		d.switch_layer(layer)!
	}
	mut data := []u8{len: 8}
	data[0] = key
	data[1] = d.build_type_byte(layer, key_type_mouse)
	data[2] = m.button
	data[3] = m.x
	data[4] = m.y
	data[5] = m.wheel
	data[6] = m.modifier
	d.send(data)!
	d.save_flash()!
}

// program_led sets the backlight mode (0, 1 or 2). Type-8 branch:
// data[2] = mode; committed with the LED save command. Uses fixed slot 0xB0
// (176), as the Windows LED page does.
pub fn (d &Device) program_led(mode u8) ! {
	mut data := []u8{len: 8}
	data[0] = 0xB0 // 176 — the LED "key slot" the Windows tool uses
	data[1] = d.build_type_byte(1, key_type_led)
	data[2] = mode
	d.send(data)!
	d.save_flash_led()!
}
