module ascii_img

import net.http
import math
import stbi
import strings
import term
import vsl.vcl

#flag -I @VMODROOT/include

// styles are the different character sets used to represent
// a pixel from the source image.
pub const styles = {
	'default': '$@B%8&WM#*oahkbdpqwmZO0QLCJUYXzcvunxrjft/\\|()1{}[]?-_+~<>i!lI;:,"^`\'. '.runes().reverse()
	'minimal': ' .:-=+*#%@'.runes()
	'nihongo': [`一`, `二`, `十`, `三`, `六`, `七`, `九`, `五`, `四`]
	'blocks':  [` `, `▏`, `▎`, `▍`, `▌`, `▋`, `▊`, `▉`, `█`]
	'solid':   [`▉`]
}

const (
	img_kernel_source = $embed_file('./ascii_img.cl')
)

// ChannelType is the different types of image channels
pub enum ChannelType {
	auto = 0
	rgba = 4 // red, green, blue, alpha
	rgb  = 3 // red, green, blue
	bwa  = 2 // black and white, alpha
	bw   = 1 // black and white
}

// HardwareAccelerationDevice is a copy of vcl.DeviceType, but
// with a none field.
pub enum HardwareAccelerationDevice as i64 {
	@none       = (0)
	cpu         = (1 << 0)
	gpu         = (1 << 1)
	accelerator = (1 << 2)
	all         = 0xFFFFFFFF
}

// ImageParams is the options passed to ascii image generator.
[params]
pub struct ImageParams {
__global:
	// If .auto is selected the stbi.load function will try to guess
	// the number of channels. But it is not guaranteed to succeed.
	channels ChannelType = .auto
	// Use scale_x without scale_y if you just want to scale if you
	// don't want to worry about the aspect ratio. By default
	// scale_y will be half of scale_x.
	scale_x f64 = 1.0
	// Monospaced fonts are typically twice the height of the character
	// width. There's probably some weirdo out there with a
	// non-monospaced font in their terminal though, so it's good to
	// have this option.
	scale_y f64 = 0.0
	// By default the terminal output is RGB compatible. Some terminals
	// don't support this.
	grayscale bool
	// Custom styles may be used. Or you may see the constant at the
	// top of the file for the preconfigured styles. The character
	// chosen from styles is chosen based off of a percentage, so the
	// style can be any amount of character you desire.
	style []rune = ascii_img.styles['default']
	// verbose prints any notices and errors that aren't fatal to the
	// ascii image generation.
	verbose bool = $if debug {
		true
	} $else {
		false
	}
	// The device type to be used for hardware acceleration.
	hardware_accelerated HardwareAccelerationDevice = .@none
	// The ID of the device to be used. If you only have one
	// of the device type installed in your system, then this
	// should be unneeded. Use `verbose` to see device IDs.
	hardware_device_id int
}

// from_url gets creates a string from the byte data fetched from
// the provided URL.
pub fn from_url(url string, params ImageParams) !string {
	img_source := (http.get(url)!).body.bytes()
	return from_memory(img_source.data, img_source.len, params)!
}

// from_file converts a local file to ascii string image.
pub fn from_file(path string, params ImageParams) !string {
	img := stbi.load(path, desired_channels: int(params.channels))!
	x := if params.scale_x > 0.0 {
		params.scale_x
	} else {
		return error('Scale must be between 0.0 and 1.0.')
	}
	y := if params.scale_y > 0.0 {
		params.scale_y
	} else {
		x / 2.0
	}
	return img_to_ascii(img, x, y, params.grayscale, params.style)
}

// from_memory converts byte data to ascii string image.
pub fn from_memory(buf &u8, size int, params ImageParams) !string {
	img := stbi.load_from_memory(buf, size, desired_channels: int(params.channels))!
	x := if params.scale_x > 0.0 {
		params.scale_x
	} else {
		return error('Scale must be between 0.0 and 1.0.')
	}
	y := if params.scale_y > 0.0 {
		params.scale_y
	} else {
		x / 2.0
	}
	return img_to_ascii(img, x, y, params.grayscale, params.style)!
}

// img_to_ascii converts an image to an ascii string.
[direct_array_access]
fn img_to_ascii(image &stbi.Image, scale_x f64, scale_y f64, grayscale bool, style []rune) !string {
	img := stbi.resize_uint8(image, int(image.width * scale_x), int(image.height * scale_y))!
	mut img_bytes := []u8{len: img.width * img.height * img.nr_channels}
	unsafe {
		vmemcpy(img_bytes.data, img.data, img_bytes.len)
	}
	// so we don't have to do if grayscale in loop
	color_fn := if grayscale {
		fn (r u8, g u8, b u8, str string) string {
			return str
		}
	} else {
		fn (r u8, g u8, b u8, str string) string {
			return term.rgb(r, g, b, str)
		}
	}
	mut bldr := strings.new_builder(img.width * img.height * img.nr_channels)
	row_len := img.width * img.nr_channels
	for y := 0; y < img.height; y++ {
		row_start := y * row_len
		for x := 0; x < row_len; x += img.nr_channels {
			pixel_start := row_start + x
			bytes := unsafe { img_bytes[pixel_start..(pixel_start + img.nr_channels)] }
			ascii := pixel_to_ascii(bytes, img.nr_channels, style)
			bldr.write_string(color_fn(bytes[0], bytes[1], bytes[2], ascii.str()))
		}
		bldr.write_string('\n')
	}
	return bldr.str()
}

// img_to_ascii_opencl allows for calculations on the GPU.
fn img_to_ascii_opencl(stb_img &stbi.Image, params ImageParams) !AsciiImage {
	mut aimg := AsciiImage{}
	scale_x := if params.scale_x > 0.0 {
		params.scale_x
	} else {
		return error('Scale must be between 0.0 and 1.0.')
	}
	scale_y := if params.scale_y > 0.0 {
		params.scale_y
	} else {
		if params.verbose {
			println('ImageParams.scale_y unset. Defaulting to half of ImageParams.scale_x.')
		}
		scale_x / 2.0
	}
	img := stbi.resize_uint8(stb_img, int(stb_img.width * scale_x), int(stb_img.height * scale_y))!
	img_size := img.width * img.height * img.nr_channels

	mut device := &vcl.Device{}
	// If we end up inside this function, params.hardware_accelerated,
	// should not be .@none.
	device_type := unsafe { vcl.DeviceType(int(params.hardware_accelerated)) }
	devices := vcl.get_devices(device_type)!
	if params.verbose {
		println('Hardware Devices: ${devices}')
	}
	if params.hardware_device_id > devices.len {
		return error('ImageParams.harware_device_id out of bounds: ${params.hardware_device_id}')
	}
	device = devices[params.hardware_device_id]
	defer {
		device.release() or {
			if params.verbose {
				println('Failed to release ${params.hardware_accelerated} hardware device with ID of ${params.hardware_device_id}. Error: ${err.msg()}')
			}
		}
	}

	mut vector_style_len := device.vector[int](1)!
	mut vector_style := device.vector[u32](params.style.len)!
	mut vector_img := device.from_image_2d(img)!
	mut vector_style_dest := device.vector[int](img.height * img.width)!
	defer {
		if params.verbose {
			vector_style_len.release() or { println('Failed to release vector: ${err.msg()}') }
			vector_style.release() or { println('Failed to release vector: ${err.msg()}') }
			vector_img.release() or { println('Failed to release vector: ${err.msg()}') }
			vector_style_dest.release() or { println('Failed to release vector: ${err.msg()}') }
		} else {
			vector_style_len.release() or {}
			vector_style.release() or {}
			vector_img.release() or {}
			vector_style_dest.release() or {}
		}
	}

	style_len := [params.style.len]
	load_style_len_err := <-vector_style_len.load(style_len)
	if load_style_len_err !is none {
		return load_style_len_err
	}
	mut style := []u32{len: params.style.len}
	unsafe {
		vmemcpy(style.data, params.style.data, sizeof(u32) * u32(params.style.len))
	}
	load_style_err := <-vector_style.load(style)
	if load_style_err !is none {
		return load_style_err
	}

	device.add_program(ascii_img.img_kernel_source.to_string())!
	k := device.kernel('gen_ascii_img')!
	kernel_err := <-k.global(img_size).local(img.nr_channels).run(vector_style_len, vector_style,
		vector_img, vector_style_dest)
	if kernel_err !is none {
		return kernel_err
	}

	dest := vector_style_dest.data() or {
		return error('Failed to get data from hardware device: ${err.msg()}')
	}

	println(dest.len)
	println(img.width * img.height)

	return aimg
}

// pixel_to_ascii takes in pixel data and converts it to the appropriate character
// in the style based on the pixel brightness.
[direct_array_access]
fn pixel_to_ascii(bytes []u8, channels int, style []rune) rune {
	mut channel_total := f64(0)
	for i in 0 .. channels {
		channel_total += f64(bytes[i])
	}
	brightness := channel_total / 4.0
	brightness_percent := brightness / 255.0
	style_i := int(math.floor(brightness_percent * f64(style.len)))
	return style[style_i]
}

// Style is a rune array used for pixel brightness
// representation in the ascii image.
pub struct Style {
	data &u32 = unsafe { nil }
	len  int
}

// Style.new *reuses* the data from src array.
[inline]
pub fn Style.new(src []rune) Style {
	return Style{
		data: src.data
		len: src.len
	}
}

// AsciiImage is an images of `AsciiPixel`'s.
pub struct AsciiImage {
pub mut:
	style  Style
	pixels []AsciiPixel
}

// AsciiPixel is a pixel of data
pub struct AsciiPixel {
pub mut:
	color Color
	pixel Rune
}

[inline]
fn (ascii_pixel AsciiPixel) color_rgba() (u8, u8, u8, u8) {
	bytes := unsafe { ascii_pixel.color.rgba }
	return bytes[0], bytes[1], bytes[2], bytes[3]
}

[inline]
fn (ascii_pixel AsciiPixel) color_int() int {
	return unsafe { ascii_pixel.color.full }
}

[inline]
fn (ascii_pixel AsciiPixel) pixel_character() rune {
	return unsafe { ascii_pixel.pixel.utf }
}

[inline]
fn (ascii_pixel AsciiPixel) pixel_int() rune {
	return unsafe { ascii_pixel.pixel.num }
}

union Rune {
	utf rune
	num int
}

union Color {
	full int
	rgba []u8
}
