# Additional pixel-pipeline bindings

Add these format-neutral functions to the curated jextract surface:

- `vips_image_hasalpha`
- `vips_extract_band`
- `vips_bandjoin`
- `vips_bandjoin_const1`
- `vips_unpremultiply`

They are needed for consumer-owned band and alpha pipelines. Do not add a
pixel-buffer wrapper, color policy, channel-order policy, or application pixel
format.

The existing public low-level API already exposes everything else required:
image dimensions/bands/format/interpretation, colourspace, cast,
`vips_image_write_to_memory`, and `g_free`.

Regenerate the bindings and add a smoke assertion that each new symbol is
callable.
