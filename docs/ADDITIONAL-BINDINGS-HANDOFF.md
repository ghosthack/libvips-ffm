# Additional pixel-pipeline bindings

Add these format-neutral functions to the curated jextract surface:

- `vips_image_hasalpha`
- `vips_extract_band`
- `vips_bandjoin`
- `vips_bandjoin_const1`
- `vips_unpremultiply`
- `vips_image_get_fields`
- `vips_image_get_typeof`
- `vips_image_get_as_string`
- `vips_image_get_blob`
- `vips_image_get_int`
- `vips_image_get_double`
- `vips_blob_get_type`
- `g_strfreev`

They are needed for consumer-owned band/alpha pipelines and metadata
enumeration. Do not add a pixel-buffer wrapper, metadata model, color policy,
channel-order policy, or application pixel format.

The existing public low-level API already exposes everything else required:
image dimensions/bands/format/interpretation, colourspace, cast,
`vips_image_write_to_memory`, and `g_free`.

Regenerate the bindings and add a smoke assertion that each new symbol is
callable.
