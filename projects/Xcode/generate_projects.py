#!/usr/bin/env python3
"""Generate the two checked-in Xcode projects from the raylib examples tree."""

import argparse
from hashlib import sha1
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CONFIGURATIONS = ("Debug", "Release")

COMMON = {
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "NO",
    "CODE_SIGN_STYLE": "Automatic",
    "GCC_C_LANGUAGE_STANDARD": "gnu11",
    "HEADER_SEARCH_PATHS": [
        "$(inherited)", "$(SRCROOT)/../../src", "$(SRCROOT)/../../src/external/glfw/include",
        "$(SRCROOT)/../../examples/others/external/include",
    ],
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "TVOS_DEPLOYMENT_TARGET": "17.0",
    "SDKROOT": "auto",
    "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator appletvos appletvsimulator",
    "SUPPORTS_MACCATALYST": "NO",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY[sdk=iphone*]": "1,2",
    "TARGETED_DEVICE_FAMILY[sdk=appletv*]": "3",
    "RAYLIB_GRAPHICS[sdk=macosx*]": "GRAPHICS_API_OPENGL_33",
    "RAYLIB_GRAPHICS[sdk=iphone*]": "GRAPHICS_API_OPENGL_ES3",
    "RAYLIB_GRAPHICS[sdk=appletv*]": "GRAPHICS_API_OPENGL_ES3",
}

SIGNING_OVERRIDES = {
    "audio_amp_envelope": {"DEVELOPMENT_TEAM": ""},
    "core_2d_camera_platformer": {
        "CODE_SIGN_IDENTITY": "Apple Development",
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": "",
        "PROVISIONING_PROFILE_SPECIFIER": "",
    },
    "core_3d_camera_free": {
        "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
        "DEVELOPMENT_TEAM": "",
        "PRODUCT_BUNDLE_IDENTIFIER[sdk=iphoneos*]": "org.raylib.core-3d-camera-free-ios",
    },
    "core_input_gestures": {"DEVELOPMENT_TEAM": ""},
}

SCHEMES_WITH_TEST_ACTION = {"raylib_game", "core_2d_camera_platformer", "core_3d_camera_free"}

UNAVAILABLE = {
    "shaders_rlgl_compute": {
        "all": "This example requires OpenGL 4.3 compute shaders and shader storage buffers. Apple OpenGL does not expose them."
    },
    "rlgl_standalone": {
        "iphone": "This example uses GLFW to create a desktop OpenGL window. Run this scheme on macOS.",
        "appletv": "This example uses GLFW to create a desktop OpenGL window. Run this scheme on macOS.",
    },
    "core_drop_files": {"appletv": "This example needs a system file drop. Run it on macOS or iPadOS."},
    "core_clipboard_text": {"appletv": "This example needs a system clipboard. Run it on macOS or iOS."},
    "textures_clipboard_image": {"appletv": "This example needs a system clipboard. Run it on macOS or iOS."},
    "core_window_flags": {
        "iphone": "This example demonstrates desktop window flags. Run it on macOS.",
        "appletv": "This example demonstrates desktop window flags. Run it on macOS.",
    },
}


def atom(value):
    if isinstance(value, int):
        return str(value)
    if re.fullmatch(r"[A-Za-z0-9_./]+", value):
        return value
    return json.dumps(value, ensure_ascii=False)


def openstep(value, level=0):
    indent = "\t" * level
    if isinstance(value, dict):
        lines = [f"{indent}\t{atom(key)} = {openstep(item, level + 1)};" for key, item in value.items()]
        return "{\n" + "\n".join(lines) + f"\n{indent}}}"
    if isinstance(value, (tuple, list)):
        if not value:
            return "()"
        lines = [f"{indent}\t{openstep(item, level + 1)}," for item in value]
        return "(\n" + "\n".join(lines) + f"\n{indent})"
    return atom(value)


class Project:
    def __init__(self, name):
        self.name = name
        self.objects = {}
        self.targets = []
        self.schemes = {}
        self.apps = []
        self.references = {}
        self.products = []
        self.root_id = self.identifier("project")
        self.package = self.add("XCLocalSwiftPackageReference", "raylib", relativePath="../..")

    def identifier(self, name):
        return sha1(f"{self.name}/{name}".encode()).hexdigest()[:24].upper()

    def add(self, kind, identity, **fields):
        identifier = self.identifier(f"{kind}/{identity}")
        self.objects[identifier] = {"isa": kind, **fields}
        return identifier

    def file(self, path, kind=None):
        if path not in self.references:
            kind = kind or {".c": "sourcecode.c.c", ".m": "sourcecode.c.objc", ".swift": "sourcecode.swift",
                            ".h": "sourcecode.c.h", ".plist": "text.plist.xml"}.get(Path(path).suffix)
            self.references[path] = self.add(
                "PBXFileReference", path, path=path, name=Path(path).name,
                sourceTree="SOURCE_ROOT", **({"lastKnownFileType": kind} if kind else {}),
            )
        return self.references[path]

    def configurations(self, name, settings):
        configurations = []
        for mode in CONFIGURATIONS:
            overrides = {}
            if name == self.name + "/project":
                overrides = {
                    "GCC_OPTIMIZATION_LEVEL": 0 if mode == "Debug" else 2,
                    "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if mode == "Debug" else "-O",
                    "ONLY_ACTIVE_ARCH": "YES" if mode == "Debug" else "NO",
                    "DEBUG_INFORMATION_FORMAT": "dwarf",
                }
            configurations.append(self.add(
                "XCBuildConfiguration", f"{name}/{mode}", name=mode, buildSettings={**settings, **overrides},
            ))
        return self.add(
            "XCConfigurationList", name, buildConfigurations=configurations,
            defaultConfigurationIsVisible=0, defaultConfigurationName="Debug",
        )

    def build_file(self, target, path, flags="", kind=None):
        fields = {"fileRef": self.file(path, kind)}
        if flags:
            fields["settings"] = {"COMPILER_FLAGS": flags}
        return self.add("PBXBuildFile", f"{target}/{path}", **fields)

    def target(self, name, sources, settings, package_product, resources=None, platform_filters=()):
        app = "PRODUCT_BUNDLE_IDENTIFIER" in settings
        product_name = f"{name}.app" if app else f"lib{name}.a"
        product = self.add("PBXFileReference", "product/" + name, path=product_name,
                           explicitFileType="wrapper.application" if app else "archive.ar",
                           includeInIndex=0, sourceTree="BUILT_PRODUCTS_DIR")
        self.products.append(product)
        sources_phase = self.add("PBXSourcesBuildPhase", name, buildActionMask=2147483647,
                                 files=[self.build_file(name, path, flags) for path, flags in sources],
                                 runOnlyForDeploymentPostprocessing=0)
        package_dependency = self.add(
            "XCSwiftPackageProductDependency", f"{name}/{package_product}",
            package=self.package, productName=package_product,
        )
        filters = {"platformFilters": platform_filters} if platform_filters else {}
        link = self.add("PBXBuildFile", f"{name}/{package_product}", productRef=package_dependency, **filters)
        framework_phase = self.add("PBXFrameworksBuildPhase", name, buildActionMask=2147483647,
                                   files=[link], runOnlyForDeploymentPostprocessing=0)
        phases = [sources_phase, framework_phase]
        if resources:
            phases.append(self.add("PBXCopyFilesBuildPhase", name, buildActionMask=2147483647,
                                   dstPath="RaylibAssets", dstSubfolderSpec=7, name="Copy Raylib Assets",
                                   files=[self.build_file(name, resources, kind="folder")],
                                   runOnlyForDeploymentPostprocessing=0))
        target = self.add("PBXNativeTarget", name, name=name, productName=name, productReference=product,
                          productType="com.apple.product-type.application" if app else "com.apple.product-type.library.static",
                          buildConfigurationList=self.configurations(name, {"PRODUCT_NAME": name, **settings}),
                          buildPhases=phases, buildRules=[], dependencies=[],
                          packageProductDependencies=[package_dependency])
        self.targets.append(target)
        if app:
            self.apps.append((name, target, product_name))
            self.schemes[name] = self.scheme(self.apps[-1:])
        return target, product

    def scheme(self, apps, launchable=True):
        scheme = ET.Element("Scheme", version="1.7")
        build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
        entries = ET.SubElement(build, "BuildActionEntries")

        def reference(parent, app):
            name, target, product = app
            ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=target,
                          BuildableName=product, BlueprintName=name, ReferencedContainer=f"container:{self.name}.xcodeproj")

        for app in apps:
            entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES",
                                  buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
            reference(entry, app)
        if launchable:
            has_test_action = apps[0][0] in SCHEMES_WITH_TEST_ACTION
            debugger = "Xcode.DebuggerFoundation.Debugger.LLDB"
            launcher = "Xcode.DebuggerFoundation.Launcher.LLDB"
            if has_test_action:
                ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier=debugger,
                              selectedLauncherIdentifier=launcher, shouldUseLaunchSchemeArgsEnv="YES",
                              shouldAutocreateTestPlan="YES")
            launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug",
                                   selectedDebuggerIdentifier=debugger, selectedLauncherIdentifier=launcher, launchStyle="0")
            if has_test_action:
                launch.attrib.update({
                    "useCustomWorkingDirectory": "NO", "ignoresPersistentStateOnLaunch": "NO",
                    "debugDocumentVersioning": "YES", "debugServiceExtension": "internal",
                    "allowLocationSimulation": "YES",
                })
            reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), apps[0])
            profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release")
            if has_test_action:
                profile.attrib.update({
                    "shouldUseLaunchSchemeArgsEnv": "YES", "savedToolIdentifier": "",
                    "useCustomWorkingDirectory": "NO", "debugDocumentVersioning": "YES",
                })
            reference(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), apps[0])
        ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
        ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
        ET.indent(scheme, space="   ")
        return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(scheme, encoding="unicode") + "\n"

    def files(self):
        for shared in ("Info.plist", "Info-tvOS.plist"):
            self.file(f"AppleAppSupport/{shared}")
        products = self.add("PBXGroup", "products", name="Products", children=self.products, sourceTree="<group>")
        root = self.add("PBXGroup", "main", children=[*self.references.values(), products], sourceTree="<group>")
        self.objects[self.root_id] = {
            "isa": "PBXProject", "attributes": {"LastUpgradeCheck": 2700},
            "buildConfigurationList": self.configurations(self.name + "/project", COMMON),
            "compatibilityVersion": "Xcode 14.0", "developmentRegion": "en",
            "hasScannedForEncodings": 0, "knownRegions": ["en", "Base"],
            "mainGroup": root, "productRefGroup": products, "projectDirPath": "",
            "projectRoot": "", "targets": self.targets,
        }
        self.objects[self.root_id]["packageReferences"] = [self.package]
        bundle = HERE / f"{self.name}.xcodeproj"
        project = {"archiveVersion": 1, "classes": {}, "objectVersion": 56,
                   "objects": self.objects, "rootObject": self.root_id}
        return {
            bundle / "project.pbxproj": "// !$*UTF8*$!\n" + openstep(project) + "\n",
            **{bundle / f"xcshareddata/xcschemes/{name}.xcscheme": content
               for name, content in self.schemes.items()},
        }


def application(project, name, source, resources=None):
    bundle_id = "org.raylib." + name.lower().replace("_", "-")
    settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": "$(SRCROOT)/AppleAppSupport/Info.plist",
        "INFOPLIST_FILE[sdk=appletv*]": "$(SRCROOT)/AppleAppSupport/Info-tvOS.plist",
        "RAYLIB_UNAVAILABLE": "",
        "RAYLIB_EDITABLE_RESOURCES": "YES" if name == "shaders_hot_reloading" else "NO",
        "INFOPLIST_KEY_CFBundleDisplayName": name,
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphone*]": "YES",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=appletv*]": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone[sdk=iphone*]":
            "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad[sdk=iphone*]":
            "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown "
            "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "LIBRARY_SEARCH_PATHS": ["$(inherited)", "$(TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)", "$(SDKROOT)/usr/lib/swift"],
        "GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "PLATFORM_APPLE_SWIFTUI", "$(RAYLIB_GRAPHICS)",
                                         "$(RAYLIB_EXAMPLE_PLATFORM)", "GL_SILENCE_DEPRECATION", "GLES_SILENCE_DEPRECATION"],
        "RAYLIB_EXAMPLE_PLATFORM[sdk=macosx*]": "PLATFORM_DESKTOP",
    }
    settings.update(SIGNING_OVERRIDES.get(name, {}))
    for sdk, message in UNAVAILABLE.get(name, {}).items():
        key = "RAYLIB_UNAVAILABLE"
        settings[key if sdk == "all" else f"{key}[sdk={sdk}*]"] = message

    launch_flags = "-DRAYLIB_MANUAL_FRAME_CONTROL=1" if name == "core_custom_frame_control" else ""
    sources = [("AppleAppSupport/Launch.c", launch_flags)]
    platform_filters = ()
    if name == "rlgl_standalone":
        sources.extend([("AppleAppSupport/StandaloneExample.c", ""), ("AppleAppSupport/StandaloneGLFW.m", "-fno-objc-arc")])
        settings["EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]"] = "Launch.c"
        settings["OTHER_LDFLAGS[sdk=macosx*]"] = ["$(inherited)", *(
            argument for framework in ("AppKit", "OpenGL", "CoreFoundation", "IOKit", "QuartzCore")
            for argument in ("-framework", framework)
        )]
        platform_filters = ("ios", "ios-simulator", "tvos", "tvos-simulator")
    else:
        sources.append((source, "-Dmain=RaylibGameMain"))
    project.target(name, sources, settings, "RaylibAppleHost", resources, platform_filters)


def build_projects():
    examples = Project("raylib")
    standard = examples.target(
        "raylib", [("AppleAppSupport/Archive.c", "")], {"SKIP_INSTALL": "YES"}, "raylib",
    )
    examples.schemes["raylib"] = examples.scheme([("raylib", standard[0], "libraylib.a")], launchable=False)
    sources = sorted((*ROOT.glob("examples/*.c"), *ROOT.glob("examples/*/*.c")))
    names = set()
    for source in sources:
        name = source.stem
        if name in names:
            raise ValueError(f"Duplicate Xcode example name: {name}")
        names.add(name)
        resources = source.parent / "resources"
        application(examples, name, "../../" + str(source.relative_to(ROOT)),
                    "../../" + str(resources.relative_to(ROOT)) if resources.is_dir() else None)
    examples.schemes["All Examples"] = examples.scheme(examples.apps, launchable=False)

    template = Project("raylib_game")
    application(template, "raylib_game", "Game.c")
    return {**template.files(), **examples.files()}, len(names)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check that the projects are up to date")
    args = parser.parse_args()
    generated, count = build_projects()
    stale = False
    for path, content in generated.items():
        if path.is_file() and path.read_text() == content:
            continue
        if args.check:
            print(f"Out of date: {path.relative_to(HERE)}")
            stale = True
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    for path in (HERE / "raylib.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme"):
        if path not in generated:
            if args.check:
                print(f"Obsolete: {path.relative_to(HERE)}")
                stale = True
            else:
                path.unlink()
    print(f"{count} example app targets")
    return int(stale)


if __name__ == "__main__":
    raise SystemExit(main())
