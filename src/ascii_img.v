module ascii_img

import net.http
import math
import stbi
import strings
import term

// styles are the different character sets used to represent
// a pixel from the source image.
pub const styles = {
	'default': '$@B%8&WM#*oahkbdpqwmZO0QLCJUYXzcvunxrjft/\\|()1{}[]?-_+~<>i!lI;:,"^`\'. '.split('').reverse()
	'minimal': ' .:-=+*#%@'.split('')
	'nihongo': ['  ', '一', '二', '十', '三', '六', '七', '九', '五', '四']
	'blocks':  ['  ', '▏', '▎', '▍', '▌', '▋', '▊', '▉', '█']
	'solid':   ['▉']
}

// ChannelType is the different types of image channels
pub enum ChannelType {
	auto = 0
	rgba = 4 // red, green, blue, alpha
	rgb = 3 // red, green, blue
	bwa = 2 // black and white, alpha
	bw = 1 // black and white
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
	style []string = ascii_img.styles['default']
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
fn img_to_ascii(image &stbi.Image, scale_x f64, scale_y f64, grayscale bool, style []string) !string {
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
			bldr.write_string(color_fn(bytes[0], bytes[1], bytes[2], ascii))
		}
		bldr.write_string('\n')
	}
	return bldr.str()
}

// pixel_to_ascii takes in pixel data and converts it to the appropriate character
// in the style based on the pixel brightness.
[direct_array_access]
fn pixel_to_ascii(bytes []u8, channels int, style []string) string {
	mut channel_total := f64(0)
	for i in 0 .. channels {
		channel_total += f64(bytes[i])
	}
	brightness := channel_total / 4.0
	brightness_percent := brightness / 255.0
	style_i := int(math.floor(brightness_percent * f64(style.len)))
	return style[style_i]
}
