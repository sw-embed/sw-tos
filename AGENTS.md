# Repository workflow instructions

Before constructing a raw command for any build, artifact conversion, upload,
hardware capture, or test operation, search this repository's `justfile`,
`scripts/`, and documentation for the tracked procedure. Use the documented
script or Just recipe exactly, including its validated options.

Do not guess at artifact formats, substitute a converter from another
repository, or change a proven format in response to a single failed operation.
First verify the documented build and transport procedure and diagnose the
failure against it.

If no suitable tracked procedure exists, add one to this repository, document
it, test it independently, and then use that procedure to create untracked or
hardware-facing artifacts. Keep generated captures and other persistent,
untracked evidence under an ignored project directory such as
`build/captures/`, not `/tmp`.
