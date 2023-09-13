// float4_u is a way to iterate over OpenCL'ls float4 type.
typedef union float4_u {
    float4 vec4;
    float arr[4];
} float4_u;

uint stylized_pixel(float4_u pixel_u, int channels, uint* style, int style_len);

__constant sampler_t sampler = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_NEAREST;

__kernel void gen_ascii_img(__global int* style_len,
                            __global uint* style,
                            __read_only image2d_t src,
                            __global int* style_dest) {
    const int2 pos = { get_global_id(0), get_global_id(1) };
    float4_u pixel_u;
    pixel_u.vec4 = read_imagef(src, sampler, pos);
    // hardcoded 4 channels
    uint style_val = stylized_pixel(pixel_u, 4, style, *style_len);
    style_dest[pos.x * pos.y] = style_val;
}

// stylized_pixel_index returns an index for a `Style` in
// ascii_img.v. Channels is unused right now. Just future
// proofing for when I make this work with 1 to 4 channels
// instead of just 4 (rgba).
uint stylized_pixel(float4_u pixel_u, int channels, uint* style, int style_len) {
    float total = 0;
    for (int i = 0; i < channels; ++i)
        total += pixel_u.arr[i];
    float brightness = total / 4.0f;
    float brightness_percent = brightness / 255.0f;
    int index = floorf(brightness_percent * style_len);
    return style[index];
}