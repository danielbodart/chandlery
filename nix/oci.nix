# A game's tree from a published image, without Docker: the layers that write
# under SUBTREE (nix/versions.json lists them, nix/update-versions finds them),
# each fetched from the registry by its digest, stacked in order by
# systemd/bin/chandlery-unpack (docs/nix.md, "Packages from GHCR layers").
#
# The OCI digest is the Nix hash, so nothing else needs pinning, and a layer the
# image did not change between versions is the same store path, not fetched
# again. GHCR serves a public image to any bearer.
{
  lib,
  fetchurl,
  stdenv,
  stdenvNoCC,
  autoPatchelfHook,
  gnutar,
  gzip,
  zstd,
}:

{
  pname,
  version,
  # ghcr.io/<owner>/<repository>
  image,
  # "sha256:<hex>", in the image's order
  layers,
  # e.g. "opt/hytale"
  subtree,
  # For a game of native code built for a distribution's FHS (Valheim): the
  # libraries to autoPatchelf its ELF files against, in this same derivation,
  # so the tree is not stored twice. null: the files as the image has them.
  elfDeps ? null,
  # Library names autoPatchelf may leave unresolved (dlopen'd, or never loaded).
  elfIgnoreMissing ? [ ],
}:

let
  host = lib.head (lib.splitString "/" image);
  repository = lib.removePrefix "${host}/" image;
  fetchLayer =
    digest:
    let
      hex = lib.removePrefix "sha256:" digest;
    in
    assert lib.hasPrefix "sha256:" digest;
    fetchurl {
      # By digest alone, so a layer two versions share is one store path.
      name = "oci-layer-${hex}";
      url = "https://${host}/v2/${repository}/blobs/${digest}";
      sha256 = hex;
      curlOptsList = [
        "-H"
        "Authorization: Bearer QQ=="
      ];
    };
  patch = elfDeps != null;
in
(if patch then stdenv else stdenvNoCC).mkDerivation (
  {
    inherit pname version;

    nativeBuildInputs = [
      gnutar
      gzip
      zstd
    ]
    ++ lib.optional patch autoPatchelfHook;

    buildCommand = ''
      sh ${../systemd/bin/chandlery-unpack} --blobs $out ${lib.escapeShellArg subtree} ${lib.escapeShellArgs (map fetchLayer layers)}
    ''
    + lib.optionalString patch ''
      autoPatchelf -- $out
    '';

    # Gigabytes of someone else's files: nothing to strip or check, and what
    # needs patching is patched above.
    dontFixup = true;

    passthru = {
      inherit image layers subtree;
    };
  }
  // lib.optionalAttrs patch {
    buildInputs = elfDeps;
    autoPatchelfIgnoreMissingDeps = elfIgnoreMissing;
  }
)
