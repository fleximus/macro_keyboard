module main

// hid.v — talking to the macro keyboard's configuration interface (mi_01) on
// Linux via libusb.
//
// Why libusb and not hidraw? On this device the config interface (USB interface
// #1) exposes ONLY an interrupt-OUT endpoint and no interrupt-IN endpoint. The
// Linux `usbhid` driver refuses to bind to such an interface ("couldn't find an
// input interrupt endpoint"), so it never creates a /dev/hidraw node for it.
// The normal keyboard/consumer/mouse interfaces (0, 2, 3) do get hidraw nodes,
// but they're not where configuration reports go.
//
// libusb lets us claim interface #1 directly (no kernel driver is bound to it,
// and auto-detach covers the rare case one is) and push the same output reports
// the Windows tool sends, to the interrupt-OUT endpoint.

#flag -lusb-1.0
#include <libusb-1.0/libusb.h>

pub const vendor_id = u16(0x1189) // 4489
pub const product_id = u16(0x8890) // 34960
pub const config_interface = 1 // mi_01 — the vendor config interface
const out_endpoint = u8(0x02) // interrupt-OUT endpoint on interface 1
const usb_timeout = u32(1000) // ms

// Opaque libusb types + the subset of the API we need.
@[typedef]
struct C.libusb_context {}

@[typedef]
struct C.libusb_device_handle {}

fn C.libusb_init(ctx &&C.libusb_context) int
fn C.libusb_exit(ctx &C.libusb_context)
fn C.libusb_open_device_with_vid_pid(ctx &C.libusb_context, vid u16, pid u16) &C.libusb_device_handle
fn C.libusb_set_auto_detach_kernel_driver(handle &C.libusb_device_handle, enable int) int
fn C.libusb_kernel_driver_active(handle &C.libusb_device_handle, iface int) int
fn C.libusb_claim_interface(handle &C.libusb_device_handle, iface int) int
fn C.libusb_release_interface(handle &C.libusb_device_handle, iface int) int
fn C.libusb_close(handle &C.libusb_device_handle)
fn C.libusb_interrupt_transfer(handle &C.libusb_device_handle, endpoint u8, data &u8, length int, transferred &int, timeout u32) int
fn C.libusb_control_transfer(handle &C.libusb_device_handle, request_type u8, request u8, value u16, index u16, data &u8, length u16, timeout u32) int

pub struct Device {
pub mut:
	report_id u8 // report id used for output reports (from the report descriptor)
mut:
	ctx        &C.libusb_context        = unsafe { nil }
	handle     &C.libusb_device_handle  = unsafe { nil }
	report_len int = 9 // bytes per report on the wire: 9 (numbered) or 8 (unnumbered)
	dry_run    bool // when true, print reports instead of sending them
}

// find_device initialises libusb and opens the keyboard by VID:PID. It does not
// yet claim the interface (open() does), so callers can report "found" first.
pub fn find_device() !Device {
	mut dev := Device{}
	if C.libusb_init(&dev.ctx) != 0 {
		return error('libusb_init failed')
	}
	dev.handle = C.libusb_open_device_with_vid_pid(dev.ctx, vendor_id, product_id)
	if dev.handle == unsafe { nil } {
		C.libusb_exit(dev.ctx)
		return error('macro keyboard (${vendor_id:04x}:${product_id:04x}) not found, or no permission to open it (try sudo or install the udev rule)')
	}
	return dev
}

// open claims the config interface and reads the report descriptor to learn the
// output report id, mirroring what the Windows tool's probe established.
pub fn (mut d Device) open() ! {
	C.libusb_set_auto_detach_kernel_driver(d.handle, 1)
	rc := C.libusb_claim_interface(d.handle, config_interface)
	if rc != 0 {
		return error('cannot claim interface ${config_interface} (libusb error ${rc}); run with sudo or install the udev rule')
	}
	// Fetch the HID report descriptor of interface 1 to find the output report
	// id. GET_DESCRIPTOR(type=0x22 report, index 0) on the interface.
	mut buf := []u8{len: 512}
	n := C.libusb_control_transfer(d.handle, 0x81, 0x06, 0x2200, u16(config_interface),
		buf.data, u16(buf.len), usb_timeout)
	if n > 0 {
		id, data_bytes := output_report_info(unsafe { buf[..n] })
		d.report_id = id
		// Full output report on the wire = optional report-id byte + the
		// descriptor's declared data length (the firmware expects the whole
		// report, e.g. 64 bytes; only the first 8 carry the command).
		d.report_len = data_bytes + if id != 0 { 1 } else { 0 }
	}
}

// report_descriptor returns the raw HID report descriptor of the config
// interface, for diagnostics (`info`).
pub fn (d &Device) report_descriptor() []u8 {
	mut buf := []u8{len: 512}
	n := C.libusb_control_transfer(d.handle, 0x81, 0x06, 0x2200, u16(config_interface),
		buf.data, u16(buf.len), usb_timeout)
	if n <= 0 {
		return []u8{}
	}
	return buf[..n]
}

// output_report_info walks a HID report descriptor and returns the report id
// and data length (in bytes) of the first Output (0x90) item — i.e. the report
// the config commands are sent in. report id is 0 for unnumbered reports.
fn output_report_info(desc []u8) (u8, int) {
	mut i := 0
	mut cur_id := u8(0)
	mut report_size := 0 // bits per field
	mut report_count := 0 // number of fields
	for i < desc.len {
		b := desc[i]
		if b == 0xFE { // long item: [0xFE][dataSize][tag][data...]
			if i + 1 >= desc.len {
				break
			}
			i += int(desc[i + 1]) + 3
			continue
		}
		size_code := b & 0x03
		data_len := if size_code == 3 { 4 } else { int(size_code) }
		tag := b & 0xFC
		mut val := u32(0)
		for j in 0 .. data_len {
			if i + 1 + j < desc.len {
				val |= u32(desc[i + 1 + j]) << (8 * j)
			}
		}
		match tag {
			0x84 { cur_id = u8(val) } // Report ID (0x85)
			0x74 { report_size = int(val) } // Report Size (0x75)
			0x94 { report_count = int(val) } // Report Count (0x95)
			0x90 { return cur_id, (report_size * report_count) / 8 } // Output (0x91)
			else {}
		}
		i += data_len + 1
	}
	return cur_id, 8
}

// send writes one configuration report to the interrupt-OUT endpoint. The wire
// report is the optional report-id byte followed by the descriptor's full data
// length (e.g. 64 bytes), zero-padded; only the first 8 bytes carry the command.
pub fn (d &Device) send(data []u8) ! {
	numbered := d.report_id != 0
	mut payload := []u8{len: d.report_len}
	off := if numbered {
		payload[0] = d.report_id
		1
	} else {
		0
	}
	for i in 0 .. 8 {
		payload[off + i] = if i < data.len { data[i] } else { u8(0) }
	}
	if d.dry_run {
		// Show only the meaningful header (report id + 8 bytes); the rest is
		// always zero padding up to report_len.
		mut hex := []string{}
		if numbered {
			hex << '${d.report_id:02x}'
		}
		for i in 0 .. 8 {
			b := if i < data.len { data[i] } else { u8(0) }
			hex << '${b:02x}'
		}
		pad := d.report_len - off - 8
		suffix := if pad > 0 { ' (+${pad} zero pad)' } else { '' }
		println('  send: ${hex.join(' ')}${suffix}')
		return
	}
	mut transferred := 0
	rc := C.libusb_interrupt_transfer(d.handle, out_endpoint, payload.data, payload.len,
		&transferred, usb_timeout)
	if rc != 0 {
		return error('interrupt transfer failed (libusb error ${rc})')
	}
	if transferred != payload.len {
		return error('short write: ${transferred}/${payload.len} bytes')
	}
}

pub fn (mut d Device) close() {
	if d.dry_run {
		return
	}
	if d.handle != unsafe { nil } {
		C.libusb_release_interface(d.handle, config_interface)
		C.libusb_close(d.handle)
		d.handle = unsafe { nil }
	}
	if d.ctx != unsafe { nil } {
		C.libusb_exit(d.ctx)
		d.ctx = unsafe { nil }
	}
}
