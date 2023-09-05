# ascii_img
Convert images into ascii (or unicode) text.
## Usage
Use either the `from_file`, `from_memory`, or `from_url` functions to generate a text output from the image. The code is well documented, so feel free to look at the source files for more information.
```v
img := ascii_img.from_file('./red-panda.png',
    scale_x: 0.5,
    scale_y: 0.25,
    grayscale: false,
    channels: .rgba,
    style: ascii_img.styles['default']
) or {
    err.msg()
}
println(img)
```
## TODO
In no particular order:
- [ ] Add custom color themes.
- [ ] Write to .txt file.
- [ ] Write to .png file.
- [ ] Add unicode style using which has 255 different characters.
- [ ] Ability to convert to V's builtin `gg.Image` for `gg` rendering.