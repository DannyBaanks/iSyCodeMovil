"""Prepare the Linux device build using published, pinned native compiler inputs."""
import hashlib
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / ".build" / "xtool-device"
# The CI job checked the llama source pin before archiving this device slice.
SOURCE = "3c9e26c90de97c94647e2d6f7f3503c1a01c4b0c"
IPA_HASH = "0a2bf4d22f35a6c19894f6dadb0e21b6b7eb7267a8ed71fe469dee4f780ab2c1"
LLAMA = "842b1880415d6f508f03b789e5ce70194def7bfd"
RESOURCE_SOURCES = ["Assets.xcassets", "App/NativeAppIntents.swift", "scripts/build-llama-xcframework.sh"]


def restore_inputs(inputs):
    with tempfile.TemporaryDirectory(dir=WORK) as directory:
        stage = Path(directory)
        if os.environ.get("ISYCODE_CI_IPA"):
            ipa = Path(os.environ["ISYCODE_CI_IPA"])
        else:
            archive = stage / "ci.zip"
            with archive.open("wb") as out:
                subprocess.run(["gh", "api", "repos/DannyBaanks/iSyCodeMovil/actions/artifacts/14454715834/zip"],
                               stdout=out, check=True)
            with ZipFile(archive) as outer:
                ipa = stage / "IysCodeMovil-unsigned.ipa"
                ipa.write_bytes(outer.read(ipa.name))
        if hashlib.sha256(ipa.read_bytes()).hexdigest() != IPA_HASH:
            raise SystemExit("El SHA-256 del IPA de referencia no coincide.")
        output = stage / "inputs"
        xc = output / "llama.xcframework"
        framework = xc / "ios-arm64" / "llama.framework"
        resources = output / "resources"
        framework.mkdir(parents=True)
        resources.mkdir(parents=True)
        prefix = "Payload/IysCodeMovil.app/"
        with ZipFile(ipa) as bundle:
            for filename in ("llama", "Info.plist"):
                (framework / filename).write_bytes(bundle.read(prefix + "Frameworks/llama.framework/" + filename))
            for name in bundle.namelist():
                if not name.startswith(prefix) or name.endswith("/"):
                    continue
                rel = Path(name.removeprefix(prefix))
                if rel.name == "Assets.car" or rel.match("AppIcon*.png") or rel.parts[0] == "Metadata.appintents":
                    destination = resources / rel
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(bundle.read(name))
            info = plistlib.loads(bundle.read(prefix + "Info.plist"))
            (output / "icons.plist").write_bytes(plistlib.dumps({k: v for k, v in info.items() if k.startswith("CFBundleIcons")}))
        (framework / "llama").chmod(0o755)
        (framework / "Headers").mkdir()
        headers = ["include/llama.h", "tools/mtmd/mtmd.h", "tools/mtmd/mtmd-helper.h"]
        headers += ["ggml/include/" + h + ".h" for h in ("ggml", "ggml-alloc", "ggml-backend",
                    "ggml-blas", "ggml-cpu", "ggml-metal", "ggml-opt", "gguf")]
        for path in headers:
            with urlopen(f"https://raw.githubusercontent.com/ggml-org/llama.cpp/{LLAMA}/{path}", timeout=40) as response:
                (framework / "Headers" / Path(path).name).write_bytes(response.read())
        (framework / "Modules").mkdir()
        (framework / "Modules/module.modulemap").write_text('framework module llama { umbrella "Headers" link "c++" link framework "Accelerate" link framework "Metal" link framework "Foundation" export * }\n')
        (xc / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundlePackageType="XFWK", XCFrameworkFormatVersion="1.0",
            AvailableLibraries=[dict(LibraryIdentifier="ios-arm64", LibraryPath="llama.framework",
                                     SupportedArchitectures=["arm64"], SupportedPlatform="ios")])))
        output.rename(inputs)


def main():
    # Reuse non-Swift Apple outputs only while their source files still match.
    subprocess.run(["git", "diff", "--quiet", SOURCE, "--", *RESOURCE_SOURCES], cwd=ROOT, check=True)
    if subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "--", *RESOURCE_SOURCES], cwd=ROOT):
        raise SystemExit("Hay recursos de entrada sin registrar. Recompila los recursos con Xcode.")
    WORK.mkdir(parents=True, exist_ok=True)
    inputs = WORK / ("inputs-" + IPA_HASH[:12])
    if not inputs.exists():
        restore_inputs(inputs)
    for file in ("Package.swift", "xtool.yml"):
        template = Path(__file__).with_name(file)
        destination = WORK / file
        if not destination.exists() or destination.read_bytes() != template.read_bytes():
            shutil.copyfile(template, destination)
    links = {"CoreSources": ROOT / "Sources", "AppSources": ROOT / "App", "Info.plist": ROOT / "Info.plist",
             "inputs": inputs, "llama.xcframework": inputs / "llama.xcframework"}
    for file in sorted((ROOT / "Sources").rglob("*")):
        if file.suffix in (".h", ".c"):
            rel = ("BridgeC/include/" if file.suffix == ".h" else "BridgeC/") + file.name
            if rel in links:
                raise ValueError(f"Nombre de bridge duplicado: {rel}")
            links[rel] = file
    for rel, target in links.items():
        link = WORK / rel
        link.parent.mkdir(parents=True, exist_ok=True)
        if not link.exists():
            link.symlink_to(target)
        elif link.resolve() != target.resolve():
            raise ValueError(f"El enlace {link} apunta a otro checkout.")


if __name__ == "__main__":
    main()
