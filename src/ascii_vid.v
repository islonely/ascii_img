module ascii_img

import cpuid
import gg
import gx
import os
import stbi
import term.ui as tui
import time

// The preset frame rates.
pub const (
	frame_rates = {
		'NTSC': 29.97
		'PAL': 25.0
		'SECAM': 25.0
	}
)

// Video is the object containing all the information needed for
// conversion to ascii.
struct Video {
mut:
	g            &gg.Context = unsafe { nil }
	frame        int
	frame_old    int
	stopwatch    time.StopWatch = time.new_stopwatch(auto_start: true)
	stopwatch2   time.StopWatch = time.new_stopwatch(auto_start: true)
	tui          &tui.Context = unsafe { nil }
	frame_index  int
pub:
	// path may be URL or path on local file system.
	path         string
	tmp_dir      string
	frame_format FrameFormat
	cpu          cpuid.CPUInfo = cpuid.info()
pub mut:
	audio_path string
	// TODO: once V fixes bug #19281 replace the type here
	// with `thread !`. And the return type on the corresponding
	// function that is spawned.
	extract_frames_thread ?thread string
	extract_audio_thread  ?thread string
	frames                []string
	frame_rate             f64 = 1.0
	frame_count  int
	ascii_multithreaded   bool = true
	ascii_params          ImageParams
}

// FrameFormat is the available file extensions for extracting
// frames from a video.
pub enum FrameFormat {
	bmp // easier on CPU; harder on storage device
	jpg // harder on CPU; easier on storage device
}

// VideoParams is the options passed to the ascii video generator.
[params]
pub struct VideoParams {
	// `Video.new` attempts to get the frame count of the source video to
	// allocate memory for the frames. If this flag is set to true, then
	// on failure to get frame count the function will procede. Otherwise
	// it will return an error.
	ignore_get_frame_count_failure bool
	// If `Video.new` fails to get frame count and
	// `ignore_get_frame_count_failure` is set to true, then it will
	// initialize the frame buffer with this number. The default fallback
	// is enough for a 2 minute video at 24 frames per second.
	fallback_frame_count int = 24 * 60 * 2
	// `Video.new` attempts to get the frame rate of the source video for
	// playback. If this flag is set to ture, then upon failure to get
	// frame rate the function will procede. Otherwise it will return
	// an error.
	ignore_get_frame_rate_failure bool
	// If `Video.new` failes to get the frame rate and
	// `ignore_get_frame_rate_failure` is set to true, then it will
	// set the playback speed to this number. See constant `frame_rate`
	// for preconfigured frame rates. Or set your own.
	fallback_frame_rate f64 = ascii_img.frame_rates['NTSC']
	// extracted_frame_format is the file type of the frames extracted
	// from the source video. See `FrameFormat` for more information.
	extracted_frame_format FrameFormat = .bmp
	// Speeds up the ascii generation process by spreading the load
	// across multiple cores/
	multithreaded_ascii_generation bool = true
	// The params used to generated ascii images.
	ascii_generation_params ImageParams  = ImageParams{
		scale_x: 0.13
		style: styles['solid']
	}
}

// Video.new instantiates a `Video`.
[inline]
pub fn Video.new(path string, params VideoParams) !&Video {
	p := os.abs_path(path)
	mut video := &Video{
		ascii_multithreaded: params.multithreaded_ascii_generation
		ascii_params: params.ascii_generation_params
		path: p
		tmp_dir: $if local_tmp ? {
			os.abs_path('./tmp/ascii_img/' + os.file_name(p).split('.')[0])
		} $else {
			os.temp_dir() + '/ascii_img/' + os.path_separator + os.file_name(p).split('.')[0]
		}
		frame_format: params.extracted_frame_format
	}
	if video.ascii_params.scale_y <= 0 {
		video.ascii_params.scale_y = video.ascii_params.scale_x / 2.0
	}
	video.frame_count = video.get_frame_count() or {
		if !params.ignore_get_frame_count_failure {
			return err
		}
		params.fallback_frame_count
	}
	video.frame_rate = video.get_frame_rate() or {
		if !params.ignore_get_frame_rate_failure {
			return err
		}
		params.fallback_frame_rate
	}
	video.audio_path = video.tmp('audio_track.mp3')
	// Start extracting frames as soon as we can to minimize waiting time.
	if !os.exists(video.tmp_dir) {
		os.mkdir_all(video.tmp_dir)!
	}
	video.extract_frames_thread = spawn video.extract_frames_from_video()
	video.extract_audio_thread = spawn video.extract_audio()
	return video
}

// buffer reads all the frames from the video and adds them to
// `Video.frames` buffer for later playback.
[direct_array_access]
pub fn (mut video Video) buffer() ! {
	// video.extract_frames_thead.wait()!
	if t := video.extract_frames_thread {
		msg := t.wait()
		if msg.len != 0 {
			return error(msg)
		}
	} else {
		video.extract_frames_from_video()
	}
	if t := video.extract_audio_thread {
		msg := t.wait()
		if msg.len != 0 {
			return error(msg)
		}
	} else {
		video.extract_audio()
	}

	// sz := video.get_frame_size()!
	mut frames := []string{len: video.frame_count}

	cores := if video.ascii_multithreaded { video.cpu.logical_cores } else { 1 }
	frames_per_core := video.frame_count / cores
	generate_ascii := fn [video, mut frames] (start int, end int) {
		for i := start; i < end; i++ {
			frames[i] = from_file(video.tmp('frame${i+1}.${video.frame_format}'), video.ascii_params) or {
				panic(err.msg())
			}
		}
	}
	mut t := []thread{}
	for i in 0..cores-1 {
		t << spawn generate_ascii((i * frames_per_core), ((i+1)*frames_per_core))
	}
	t << spawn generate_ascii((cores - 1) * frames_per_core, frames.len)
	t.wait()
	video.frames = frames
	unsafe {
		frames.free()
	}
}

pub fn (mut video Video) play_gg() {
	// this is big no no. The video FPS doesn't match the gg render FPS.
	// It's about 0.75% slower.
	sleep_time := 1000000000.0 / video.frame_rate * 0.9890008
	println('source fps: ${video.frame_rate}')
	font_size := 13

	frame := fn [font_size, sleep_time] (mut video Video) {
		mut continue_time := time.now().add(sleep_time)
		if _unlikely_(video.frame_index >= video.frames.len) {
			video.g.quit()
		}
		video.g.begin()

		for i, line in video.frames[video.frame_index].split_into_lines() {
			video.g.draw_text_default(0, i * font_size, line)
		}
		video.frame_index++

		video.g.end()
		for time.now() < continue_time {}
	}

	w, h := video.get_resolution() or {
		println('Failed to get video dimensions: ${err.msg()}\nDefaulting to 800x600.')
		800, 600
	}
	video.g = gg.new_context(
		font_bytes_normal: $embed_file('../fonts/Courier_Prime/CourierPrime-Regular.ttf').to_bytes()
		bg_color: gx.black
		width: int(w * font_size / 2 * video.ascii_params.scale_x)
		height: int(h * font_size * video.ascii_params.scale_y)
		window_title: os.file_name(video.path)
		frame_fn: frame
		user_data: video
	)
	video.g.run()
	
}

pub fn (mut video Video) play_terminal(term_ui bool) {
	// for some reason V sleeps in nanoseconds instead of milliseconds
	// like every other language
	sleep_time := 1000000000.0 / video.frame_rate * 0.9886
	if term_ui {
		frame := fn [sleep_time] (mut video Video) {
			if _unlikely_(video.frame_index >= video.frames.len) {
				video.tui.clear()
				video.tui.draw_text(1, 1, 'Press escape to exit...')
				video.tui.flush()
				return
			}

			video.tui.set_cursor_position(0, 0)
			// video.tui.draw_text(1, 1, video.frames[video.frame_index])
			println(video.frames[video.frame_index])
			video.frame_index++
			video.tui.flush()
			time.sleep(sleep_time)
		}

		video.tui = tui.init(
			user_data: video
			frame_fn: frame
			hide_cursor: true
		)
		video.tui.run() or {
			println('Failed to play video: ${err.msg()}')
		}
	} else {
		for video.frame_index < video.frames.len {
			continue_time := time.now().add(sleep_time)
			println(video.frames[video.frame_index])
			video.frame_index++
			// time.sleep(sleep_time)
			for time.now() < continue_time {}
		}
	}
}

// clean deletes the frames extracted from the source video.
pub fn (video Video) clean() {
	os.rmdir_all(video.tmp_dir) or { println('[os.rmdir_all] ${err.msg()}') }
}

// extract_frames_from_video extracts the frames from the source video
// to the `Video.tmp_dir` directory.
fn (video Video) extract_frames_from_video() string /* ! */ {
	result := os.execute('ffmpeg -i "${video.path}" "${video.tmp_dir}${os.path_separator}frame%d.${video.frame_format}"')
	if result.exit_code != 0 {
		// return error(result.output)
		return result.output
	}
	return ''
}

// extract_audio extracts the audio stream from the source video to the
// `Video.tmp_dir` directory.
fn (mut video Video) extract_audio() string {
	result := os.execute('ffmpeg -y -i "${video.path}" -f mp3 -ab 120000 -vn "${video.tmp('audio_track.mp3')}"')
	if result.exit_code != 0 {
		// return error(result.output)
		return result.output
	}
	return ''
}

// get_resolution returns the dimenisions of the video (i.e. 1280x720).
fn (video Video) get_resolution() !(int, int) {
	result := os.execute('ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0:s=x "${video.path}"')
	if result.exit_code == 0 {
		wh := result.output.split('x')
		return wh[0].int(), wh[1].int()
	} else {
		return error(result.output)
	}
}

// get_frame_rate returns the playback speed of the video in frames per second.
fn (video Video) get_frame_rate() !f64 {
	result := os.execute('ffprobe -v error -select_streams v -of default=noprint_wrappers=1:nokey=1 -show_entries stream=r_frame_rate "${video.path}"')
	if result.exit_code != 0 {
		return error(result.output)
	}
	// the command returns '30000/1001' instead of '29.97002997'
	frame_rate_fraction := result.output.split('/')
	return frame_rate_fraction[0].f64() / frame_rate_fraction[1].f64()
}

// get_frame_size returns the size of a single frame in bytes.
fn (video Video) get_frame_size() !int {
	sz := os.file_size(video.tmp('frame1.${video.frame_format}'))
	if sz == 0 {
		return error('Frame size of 0 bytes.')
	}
	if sz > 2147483647 {
		return error('File size capped by V array index type of int. As of 9-5-2023, V has plans to change the type to u64 on 64-bit machines.')
	}
	return int(sz)
}

// tmp returns the path to a file in the temporary directory.
[inline]
fn (video Video) tmp(str string) string {
	return os.abs_path(video.tmp_dir + os.path_separator + str)
}

// get_frame_count returns the number of frames a video contains.
fn (video Video) get_frame_count() !int {
	result := os.execute('ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "${video.path}"')
	if result.exit_code == 0 {
		return result.output.int()
	} else {
		return error(result.output)
	}
}
