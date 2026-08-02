# Additional pixel-pipeline bindings

Add these format-neutral functions to the curated jextract surface:

- `vips_image_hasalpha`
- `vips_extract_band`
- `vips_bandjoin`
- `vips_bandjoin_const1`
- `vips_unpremultiply`
- `vips_icc_import`
- `vips_icc_transform`
- `vips_image_get_fields`
- `vips_image_get_typeof`
- `vips_image_get_as_string`
- `vips_image_get_blob`
- `vips_image_get_int`
- `vips_image_get_double`
- `vips_blob_get_type`
- `g_strfreev`

They are needed for consumer-owned band/alpha and profile-aware color
pipelines, plus metadata enumeration. Do not add a pixel-buffer wrapper,
metadata model, color policy, channel-order policy, or application pixel
format.

With these additions, the public low-level API exposes the format-neutral
primitives required by the consumer pipeline: image
dimensions/bands/format/interpretation, profile-aware ICC import/transform,
colourspace, cast, `vips_image_write_to_memory`, and `g_free`.

A consumer promising sRGB output must use `vips_icc_import` or
`vips_icc_transform` when an input has an embedded ICC profile.
`vips_colourspace(..., VIPS_INTERPRETATION_sRGB, ...)` converts according to
the image interpretation but does not by itself apply an embedded profile.
The binding supplies both mechanisms; choosing when to honor a profile and
which fallback to use remains consumer-owned color policy.

Regenerate the bindings and add a smoke assertion that each new symbol is
callable.
