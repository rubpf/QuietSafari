#!/usr/bin/env python3
"""Write QuietSafari.xcodeproj. The committed project is the output of this script."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "QuietSafari.xcodeproj"
PBXPROJ = PROJECT / "project.pbxproj"
SCHEME = PROJECT / "xcshareddata" / "xcschemes" / "QuietSafari.xcscheme"
WORKSPACE = PROJECT / "project.xcworkspace" / "contents.xcworkspacedata"


class Ref:
    def __init__(self, identifier: str, comment: str | None = None):
        self.identifier = identifier
        self.comment = comment

    def render(self) -> str:
        if not self.comment:
            return self.identifier
        return f"{self.identifier} /* {self.comment.replace('*/', '')} */"


class Raw:
    def __init__(self, text: str):
        self.text = text


class Project:
    def __init__(self):
        self.counter = 0
        self.objects: list[tuple[str, str, str, dict]] = []

    def add(self, isa: str, comment: str, fields: dict) -> str:
        self.counter += 1
        identifier = f"A1{self.counter:022X}"
        body = {"isa": isa}
        body.update(fields)
        self.objects.append((isa, identifier, comment, body))
        return identifier

    def ref(self, identifier: str, comment: str | None = None) -> Ref:
        return Ref(identifier, comment)


def quote(text: str) -> str:
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def emit_key(key) -> str:
    if isinstance(key, Raw):
        return key.text
    if isinstance(key, str) and key.replace("_", "").replace(".", "").isalnum() and not key[:1].isdigit():
        return key
    return quote(str(key))


def emit(value, indent: int) -> str:
    pad = "\t" * indent
    if isinstance(value, Ref):
        return value.render()
    if isinstance(value, Raw):
        return value.text
    if isinstance(value, bool):
        return "YES" if value else "NO"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return quote(value)
    if isinstance(value, list):
        if not value:
            return "(\n" + pad + ")"
        lines = ["("]
        for item in value:
            lines.append(f"{pad}\t{emit(item, indent + 1)},")
        lines.append(f"{pad})")
        return "\n".join(lines)
    if isinstance(value, dict):
        lines = ["{"]
        for key, item in value.items():
            lines.append(f"{pad}\t{emit_key(key)} = {emit(item, indent + 1)};")
        lines.append(f"{pad}}}")
        return "\n".join(lines)
    raise TypeError(type(value))


def require(relative: str) -> None:
    path = ROOT / relative
    if not path.exists():
        raise SystemExit(f"missing project input: {relative}")


def build_settings(debug: bool) -> dict:
    settings: dict = {
        "ALWAYS_SEARCH_USER_PATHS": False,
        "CLANG_ANALYZER_NONNULL": True,
        "CLANG_ENABLE_MODULES": True,
        "CLANG_ENABLE_OBJC_ARC": True,
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": True,
        "CLANG_WARN_BOOL_CONVERSION": True,
        "CLANG_WARN_EMPTY_BODY": True,
        "CLANG_WARN_ENUM_CONVERSION": True,
        "CLANG_WARN_INFINITE_RECURSION": True,
        "CLANG_WARN_INT_CONVERSION": True,
        "CLANG_WARN_UNREACHABLE_CODE": True,
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": True,
        "CODE_SIGN_STYLE": "Automatic",
        "COPY_PHASE_STRIP": False,
        "ENABLE_HARDENED_RUNTIME": True,
        "ENABLE_STRICT_OBJC_MSGSEND": True,
        "ENABLE_USER_SCRIPT_SANDBOXING": True,
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": True,
        "GCC_WARN_UNUSED_VARIABLE": True,
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "SDKROOT": "macosx",
        "STRING_CATALOG_GENERATE_SYMBOLS": False,
        "SWIFT_VERSION": "5.0",
    }
    if debug:
        settings.update(
            {
                "DEBUG_INFORMATION_FORMAT": "dwarf",
                "ENABLE_NS_ASSERTIONS": True,
                "ENABLE_TESTABILITY": True,
                "GCC_DYNAMIC_NO_PIC": False,
                "GCC_OPTIMIZATION_LEVEL": "0",
                "ONLY_ACTIVE_ARCH": True,
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
                "SWIFT_COMPILATION_MODE": "singlefile",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            }
        )
    else:
        settings.update(
            {
                "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                "ENABLE_NS_ASSERTIONS": False,
                "GCC_OPTIMIZATION_LEVEL": "s",
                "SWIFT_COMPILATION_MODE": "wholemodule",
                "SWIFT_OPTIMIZATION_LEVEL": "-O",
            }
        )
    return dict(sorted(settings.items()))


def configuration(project: Project, xcconfig: str, name: str, settings: dict) -> str:
    return project.add(
        "XCBuildConfiguration",
        name,
        {
            "baseConfigurationReference": project.ref(xcconfig, "Shared.xcconfig"),
            "buildSettings": settings,
            "name": name,
        },
    )


def config_list(project: Project, debug_id: str, release_id: str, comment: str) -> str:
    return project.add(
        "XCConfigurationList",
        comment,
        {
            "buildConfigurations": [
                project.ref(debug_id, "Debug"),
                project.ref(release_id, "Release"),
            ],
            "defaultConfigurationIsVisible": 0,
            "defaultConfigurationName": "Release",
        },
    )


def file_ref(project: Project, filename: str, file_type: str, disk: str) -> str:
    require(disk)
    return project.add(
        "PBXFileReference",
        filename,
        {
            "lastKnownFileType": file_type,
            "path": filename,
            "sourceTree": "<group>",
        },
    )


def group(project: Project, name: str, path: str | None, children: list[Ref], show_name: bool = True) -> str:
    fields: dict = {
        "children": children,
        "sourceTree": "<group>",
    }
    if path is not None:
        fields["path"] = path
    elif show_name:
        fields["name"] = name
    return project.add("PBXGroup", name, fields)


def build_file(project: Project, file_id: str, comment: str, settings: dict | None = None) -> str:
    fields: dict = {"fileRef": project.ref(file_id, comment)}
    if settings:
        fields["settings"] = settings
    return project.add("PBXBuildFile", comment, fields)


def phase(project: Project, isa: str, name: str, files: list[Ref], extra: dict | None = None) -> str:
    fields: dict = {
        "buildActionMask": 2147483647,
        "files": files,
        "name": name,
        "runOnlyForDeploymentPostprocessing": 0,
    }
    if extra:
        fields.update(extra)
    return project.add(isa, name, fields)


def render() -> tuple[str, str, str, dict[str, str]]:
    project = Project()

    app_sources = {
        "QuietSafariApp.swift": file_ref(project, "QuietSafariApp.swift", "sourcecode.swift", "App/QuietSafariApp.swift"),
        "ContentView.swift": file_ref(project, "ContentView.swift", "sourcecode.swift", "App/ContentView.swift"),
        "SettingsStore.swift": file_ref(project, "SettingsStore.swift", "sourcecode.swift", "App/SettingsStore.swift"),
        "RuleCompiler.swift": file_ref(project, "RuleCompiler.swift", "sourcecode.swift", "App/RuleCompiler.swift"),
        "TestPageServer.swift": file_ref(project, "TestPageServer.swift", "sourcecode.swift", "App/TestPageServer.swift"),
        "FilterConverter.swift": file_ref(project, "FilterConverter.swift", "sourcecode.swift", "App/FilterConverter.swift"),
        "FilterLibrary.swift": file_ref(project, "FilterLibrary.swift", "sourcecode.swift", "App/FilterLibrary.swift"),
        "MenuBar.swift": file_ref(project, "MenuBar.swift", "sourcecode.swift", "App/MenuBar.swift"),
        "QuietSafariPalette.swift": file_ref(project, "QuietSafariPalette.swift", "sourcecode.swift", "App/QuietSafariPalette.swift"),
    }
    app_plist = file_ref(project, "Info.plist", "text.plist.xml", "App/Info.plist")
    app_ents = file_ref(project, "QuietSafari.entitlements", "text.plist.entitlements", "App/QuietSafari.entitlements")
    test_page = file_ref(project, "TestPage.html", "text.html", "App/TestPage.html")
    assets = file_ref(project, "Assets.xcassets", "folder.assetcatalog", "App/Assets.xcassets")

    blocker_source = file_ref(
        project,
        "ContentBlockerRequestHandler.swift",
        "sourcecode.swift",
        "ContentBlocker/ContentBlockerRequestHandler.swift",
    )
    blocker_plist = file_ref(project, "Info.plist", "text.plist.xml", "ContentBlocker/Info.plist")
    blocker_ents = file_ref(
        project,
        "QuietSafariContentBlocker.entitlements",
        "text.plist.entitlements",
        "ContentBlocker/QuietSafariContentBlocker.entitlements",
    )
    privacy_plist = file_ref(project, "Info.plist", "text.plist.xml", "Privacy/Info.plist")
    russian_plist = file_ref(project, "Info.plist", "text.plist.xml", "Russian/Info.plist")

    ext_source = file_ref(
        project,
        "SafariWebExtensionHandler.swift",
        "sourcecode.swift",
        "Extension/SafariWebExtensionHandler.swift",
    )
    ext_plist = file_ref(project, "Info.plist", "text.plist.xml", "Extension/Info.plist")
    ext_ents = file_ref(
        project,
        "QuietSafariExtension.entitlements",
        "text.plist.entitlements",
        "Extension/QuietSafariExtension.entitlements",
    )
    resource_files = {
        "manifest.json": file_ref(project, "manifest.json", "text.json", "Extension/Resources/manifest.json"),
        "background.js": file_ref(project, "background.js", "sourcecode.javascript", "Extension/Resources/background.js"),
        "cosmetic.js": file_ref(project, "cosmetic.js", "sourcecode.javascript", "Extension/Resources/cosmetic.js"),
        "youtube.js": file_ref(project, "youtube.js", "sourcecode.javascript", "Extension/Resources/youtube.js"),
        "popup.html": file_ref(project, "popup.html", "text.html", "Extension/Resources/popup.html"),
        "popup.css": file_ref(project, "popup.css", "text.css", "Extension/Resources/popup.css"),
        "popup.js": file_ref(project, "popup.js", "sourcecode.javascript", "Extension/Resources/popup.js"),
        "youtube-main.js": file_ref(project, "youtube-main.js", "sourcecode.javascript", "Extension/Resources/youtube-main.js"),
        "engine.js": file_ref(project, "engine.js", "sourcecode.javascript", "Extension/Resources/engine.js"),
        "engine-rules.js": file_ref(project, "engine-rules.js", "sourcecode.javascript", "Extension/Resources/engine-rules.js"),
        "cookies.js": file_ref(project, "cookies.js", "sourcecode.javascript", "Extension/Resources/cookies.js"),
    }
    images = project.add(
        "PBXFileReference",
        "images",
        {
            "lastKnownFileType": "folder",
            "path": "images",
            "sourceTree": "<group>",
        },
    )
    require("Extension/Resources/images")

    shared_swift = file_ref(project, "QuietSafariShared.swift", "sourcecode.swift", "Shared/QuietSafariShared.swift")
    rules = file_ref(project, "blockerList.json", "text.json", "Shared/blockerList.json")
    privacy_rules = file_ref(project, "privacyList.json", "text.json", "Shared/privacyList.json")
    russian_rules = file_ref(project, "russianList.json", "text.json", "Shared/russianList.json")
    filter_counts = file_ref(project, "filter-counts.json", "text.json", "Shared/filter-counts.json")
    xcconfig = file_ref(project, "Shared.xcconfig", "text.xcconfig", "Config/Shared.xcconfig")
    local_example = file_ref(project, "Local.xcconfig.example", "text", "Config/Local.xcconfig.example")
    architecture = file_ref(project, "ARCHITECTURE.md", "net.daringfireball.markdown", "docs/ARCHITECTURE.md")
    roadmap = file_ref(project, "ROADMAP.md", "net.daringfireball.markdown", "docs/ROADMAP.md")
    readme = file_ref(project, "README.md", "net.daringfireball.markdown", "README.md")

    safari_fw = project.add(
        "PBXFileReference",
        "SafariServices.framework",
        {
            "lastKnownFileType": "wrapper.framework",
            "name": "SafariServices.framework",
            "path": "System/Library/Frameworks/SafariServices.framework",
            "sourceTree": "SDKROOT",
        },
    )
    network_fw = project.add(
        "PBXFileReference",
        "Network.framework",
        {
            "lastKnownFileType": "wrapper.framework",
            "name": "Network.framework",
            "path": "System/Library/Frameworks/Network.framework",
            "sourceTree": "SDKROOT",
        },
    )

    app_product = project.add(
        "PBXFileReference",
        "QuietSafari.app",
        {
            "explicitFileType": "wrapper.application",
            "includeInIndex": 0,
            "path": "QuietSafari.app",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    ext_product = project.add(
        "PBXFileReference",
        "QuietSafariExtension.appex",
        {
            "explicitFileType": "wrapper.app-extension",
            "includeInIndex": 0,
            "path": "QuietSafariExtension.appex",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    blocker_product = project.add(
        "PBXFileReference",
        "QuietSafariContentBlocker.appex",
        {
            "explicitFileType": "wrapper.app-extension",
            "includeInIndex": 0,
            "path": "QuietSafariContentBlocker.appex",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    privacy_product = project.add(
        "PBXFileReference",
        "QuietSafariPrivacy.appex",
        {
            "explicitFileType": "wrapper.app-extension",
            "includeInIndex": 0,
            "path": "QuietSafariPrivacy.appex",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )
    russian_product = project.add(
        "PBXFileReference",
        "QuietSafariRussian.appex",
        {
            "explicitFileType": "wrapper.app-extension",
            "includeInIndex": 0,
            "path": "QuietSafariRussian.appex",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        },
    )

    resources_group = group(
        project,
        "Resources",
        "Resources",
        [project.ref(resource_files[name], name) for name in resource_files] + [project.ref(images, "images")],
    )
    app_group = group(
        project,
        "App",
        "App",
        [
            project.ref(app_sources["QuietSafariApp.swift"], "QuietSafariApp.swift"),
            project.ref(app_sources["ContentView.swift"], "ContentView.swift"),
            project.ref(app_sources["SettingsStore.swift"], "SettingsStore.swift"),
            project.ref(app_sources["RuleCompiler.swift"], "RuleCompiler.swift"),
            project.ref(app_sources["TestPageServer.swift"], "TestPageServer.swift"),
            project.ref(app_sources["FilterConverter.swift"], "FilterConverter.swift"),
            project.ref(app_sources["FilterLibrary.swift"], "FilterLibrary.swift"),
            project.ref(app_sources["MenuBar.swift"], "MenuBar.swift"),
            project.ref(app_sources["QuietSafariPalette.swift"], "QuietSafariPalette.swift"),
            project.ref(assets, "Assets.xcassets"),
            project.ref(test_page, "TestPage.html"),
            project.ref(app_plist, "Info.plist"),
            project.ref(app_ents, "QuietSafari.entitlements"),
        ],
    )
    ext_group = group(
        project,
        "Extension",
        "Extension",
        [
            project.ref(ext_source, "SafariWebExtensionHandler.swift"),
            project.ref(resources_group, "Resources"),
            project.ref(ext_plist, "Info.plist"),
            project.ref(ext_ents, "QuietSafariExtension.entitlements"),
        ],
    )
    blocker_group = group(
        project,
        "ContentBlocker",
        "ContentBlocker",
        [
            project.ref(blocker_source, "ContentBlockerRequestHandler.swift"),
            project.ref(blocker_plist, "Info.plist"),
            project.ref(blocker_ents, "QuietSafariContentBlocker.entitlements"),
        ],
    )
    privacy_group = group(
        project,
        "Privacy",
        "Privacy",
        [
            project.ref(privacy_plist, "Info.plist"),
        ],
    )
    russian_group = group(
        project,
        "Russian",
        "Russian",
        [
            project.ref(russian_plist, "Info.plist"),
        ],
    )
    shared_group = group(
        project,
        "Shared",
        "Shared",
        [
            project.ref(shared_swift, "QuietSafariShared.swift"),
            project.ref(rules, "blockerList.json"),
            project.ref(privacy_rules, "privacyList.json"),
            project.ref(russian_rules, "russianList.json"),
            project.ref(filter_counts, "filter-counts.json"),
        ],
    )
    config_group = group(
        project,
        "Config",
        "Config",
        [
            project.ref(xcconfig, "Shared.xcconfig"),
            project.ref(local_example, "Local.xcconfig.example"),
        ],
    )
    docs_group = group(
        project,
        "docs",
        "docs",
        [
            project.ref(architecture, "ARCHITECTURE.md"),
            project.ref(roadmap, "ROADMAP.md"),
        ],
    )
    frameworks_group = group(
        project,
        "Frameworks",
        None,
        [
            project.ref(safari_fw, "SafariServices.framework"),
            project.ref(network_fw, "Network.framework"),
        ],
    )
    products_group = group(
        project,
        "Products",
        None,
        [
            project.ref(app_product, "QuietSafari.app"),
            project.ref(ext_product, "QuietSafariExtension.appex"),
            project.ref(blocker_product, "QuietSafariContentBlocker.appex"),
            project.ref(privacy_product, "QuietSafariPrivacy.appex"),
            project.ref(russian_product, "QuietSafariRussian.appex"),
        ],
    )
    main_group = group(
        project,
        "QuietSafari",
        None,
        [
            project.ref(app_group, "App"),
            project.ref(ext_group, "Extension"),
            project.ref(blocker_group, "ContentBlocker"),
            project.ref(privacy_group, "Privacy"),
            project.ref(russian_group, "Russian"),
            project.ref(shared_group, "Shared"),
            project.ref(config_group, "Config"),
            project.ref(docs_group, "docs"),
            project.ref(readme, "README.md"),
            project.ref(frameworks_group, "Frameworks"),
            project.ref(products_group, "Products"),
        ],
        show_name=False,
    )

    def source_phase(pairs: list[tuple[str, str]]) -> str:
        files = [project.ref(build_file(project, file_id, name), name) for file_id, name in pairs]
        return phase(project, "PBXSourcesBuildPhase", "Sources", files)

    def resource_phase(pairs: list[tuple[str, str]]) -> str:
        files = [project.ref(build_file(project, file_id, name), name) for file_id, name in pairs]
        return phase(project, "PBXResourcesBuildPhase", "Resources", files)

    def framework_phase(pairs: list[tuple[str, str]]) -> str:
        files = [project.ref(build_file(project, file_id, name), name) for file_id, name in pairs]
        return phase(project, "PBXFrameworksBuildPhase", "Frameworks", files)

    app_sources_phase = source_phase(
        [(app_sources[name], name) for name in app_sources] + [(shared_swift, "QuietSafariShared.swift")]
    )
    app_resources_phase = resource_phase(
        [
            (assets, "Assets.xcassets"),
            (test_page, "TestPage.html"),
            (rules, "blockerList.json"),
            (privacy_rules, "privacyList.json"),
            (russian_rules, "russianList.json"),
            (filter_counts, "filter-counts.json"),
        ]
    )
    app_frameworks_phase = framework_phase(
        [
            (safari_fw, "SafariServices.framework"),
            (network_fw, "Network.framework"),
        ]
    )
    embed_ext = build_file(
        project,
        ext_product,
        "QuietSafariExtension.appex",
        {"ATTRIBUTES": [Raw("CodeSignOnCopy"), Raw("RemoveHeadersOnCopy")]},
    )
    embed_blocker = build_file(
        project,
        blocker_product,
        "QuietSafariContentBlocker.appex",
        {"ATTRIBUTES": [Raw("CodeSignOnCopy"), Raw("RemoveHeadersOnCopy")]},
    )
    embed_privacy = build_file(
        project,
        privacy_product,
        "QuietSafariPrivacy.appex",
        {"ATTRIBUTES": [Raw("CodeSignOnCopy"), Raw("RemoveHeadersOnCopy")]},
    )
    embed_russian = build_file(
        project,
        russian_product,
        "QuietSafariRussian.appex",
        {"ATTRIBUTES": [Raw("CodeSignOnCopy"), Raw("RemoveHeadersOnCopy")]},
    )
    embed_phase = phase(
        project,
        "PBXCopyFilesBuildPhase",
        "Embed Foundation Extensions",
        [
            project.ref(embed_ext, "QuietSafariExtension.appex"),
            project.ref(embed_blocker, "QuietSafariContentBlocker.appex"),
            project.ref(embed_privacy, "QuietSafariPrivacy.appex"),
            project.ref(embed_russian, "QuietSafariRussian.appex"),
        ],
        {"dstPath": "", "dstSubfolderSpec": 13, "name": "Embed Foundation Extensions"},
    )

    ext_sources_phase = source_phase(
        [
            (ext_source, "SafariWebExtensionHandler.swift"),
            (shared_swift, "QuietSafariShared.swift"),
        ]
    )
    ext_resources_phase = resource_phase(
        [(resource_files[name], name) for name in resource_files] + [(images, "images")]
    )
    ext_frameworks_phase = framework_phase([(safari_fw, "SafariServices.framework")])

    blocker_sources_phase = source_phase(
        [
            (blocker_source, "ContentBlockerRequestHandler.swift"),
            (shared_swift, "QuietSafariShared.swift"),
        ]
    )
    blocker_resources_phase = resource_phase([(rules, "blockerList.json")])
    blocker_frameworks_phase = framework_phase([])
    privacy_sources_phase = source_phase(
        [
            (blocker_source, "ContentBlockerRequestHandler.swift"),
            (shared_swift, "QuietSafariShared.swift"),
        ]
    )
    privacy_resources_phase = resource_phase([(privacy_rules, "privacyList.json")])
    privacy_frameworks_phase = framework_phase([])
    russian_sources_phase = source_phase(
        [
            (blocker_source, "ContentBlockerRequestHandler.swift"),
            (shared_swift, "QuietSafariShared.swift"),
        ]
    )
    russian_resources_phase = resource_phase([(russian_rules, "russianList.json")])
    russian_frameworks_phase = framework_phase([])

    runpaths_app = ["$(inherited)", "@executable_path/../Frameworks"]
    runpaths_ext = [
        "$(inherited)",
        "@executable_path/../Frameworks",
        "@executable_path/../../../../Frameworks",
    ]

    def target_settings(extra: dict) -> tuple[str, str]:
        debug = configuration(project, xcconfig, "Debug", dict(sorted(extra.items())))
        release = configuration(project, xcconfig, "Release", dict(sorted(extra.items())))
        return debug, release

    app_debug, app_release = target_settings(
        {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "CODE_SIGN_ENTITLEMENTS": "App/QuietSafari.entitlements",
            "COMBINE_HIDPI_IMAGES": True,
            "GENERATE_INFOPLIST_FILE": False,
            "INFOPLIST_FILE": "App/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": runpaths_app,
            "PRODUCT_BUNDLE_IDENTIFIER": "$(QUIETSAFARI_APP_BUNDLE_ID)",
            "PRODUCT_MODULE_NAME": "QuietSafari",
            "PRODUCT_NAME": "QuietSafari",
            "WRAPPER_EXTENSION": "app",
        }
    )
    ext_debug, ext_release = target_settings(
        {
            "APPLICATION_EXTENSION_API_ONLY": True,
            "CODE_SIGN_ENTITLEMENTS": "Extension/QuietSafariExtension.entitlements",
            "GENERATE_INFOPLIST_FILE": False,
            "INFOPLIST_FILE": "Extension/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": runpaths_ext,
            "PRODUCT_BUNDLE_IDENTIFIER": "$(QUIETSAFARI_EXTENSION_BUNDLE_ID)",
            "PRODUCT_MODULE_NAME": "QuietSafariExtension",
            "PRODUCT_NAME": "QuietSafariExtension",
            "SKIP_INSTALL": True,
            "WRAPPER_EXTENSION": "appex",
        }
    )
    blocker_debug, blocker_release = target_settings(
        {
            "APPLICATION_EXTENSION_API_ONLY": True,
            "CODE_SIGN_ENTITLEMENTS": "ContentBlocker/QuietSafariContentBlocker.entitlements",
            "GENERATE_INFOPLIST_FILE": False,
            "INFOPLIST_FILE": "ContentBlocker/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": runpaths_ext,
            "PRODUCT_BUNDLE_IDENTIFIER": "$(QUIETSAFARI_BLOCKER_BUNDLE_ID)",
            "PRODUCT_MODULE_NAME": "QuietSafariContentBlocker",
            "PRODUCT_NAME": "QuietSafariContentBlocker",
            "SKIP_INSTALL": True,
            "WRAPPER_EXTENSION": "appex",
        }
    )
    privacy_debug, privacy_release = target_settings(
        {
            "APPLICATION_EXTENSION_API_ONLY": True,
            "CODE_SIGN_ENTITLEMENTS": "ContentBlocker/QuietSafariContentBlocker.entitlements",
            "GENERATE_INFOPLIST_FILE": False,
            "INFOPLIST_FILE": "Privacy/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": runpaths_ext,
            "PRODUCT_BUNDLE_IDENTIFIER": "$(QUIETSAFARI_PRIVACY_BUNDLE_ID)",
            "PRODUCT_MODULE_NAME": "QuietSafariPrivacy",
            "PRODUCT_NAME": "QuietSafariPrivacy",
            "SKIP_INSTALL": True,
            "WRAPPER_EXTENSION": "appex",
        }
    )
    russian_debug, russian_release = target_settings(
        {
            "APPLICATION_EXTENSION_API_ONLY": True,
            "CODE_SIGN_ENTITLEMENTS": "ContentBlocker/QuietSafariContentBlocker.entitlements",
            "GENERATE_INFOPLIST_FILE": False,
            "INFOPLIST_FILE": "Russian/Info.plist",
            "LD_RUNPATH_SEARCH_PATHS": runpaths_ext,
            "PRODUCT_BUNDLE_IDENTIFIER": "$(QUIETSAFARI_RUSSIAN_BUNDLE_ID)",
            "PRODUCT_MODULE_NAME": "QuietSafariRussian",
            "PRODUCT_NAME": "QuietSafariRussian",
            "SKIP_INSTALL": True,
            "WRAPPER_EXTENSION": "appex",
        }
    )
    project_debug = configuration(project, xcconfig, "Debug", build_settings(True))
    project_release = configuration(project, xcconfig, "Release", build_settings(False))

    app_list = config_list(project, app_debug, app_release, 'Build configuration list for PBXNativeTarget "QuietSafari"')
    ext_list = config_list(
        project, ext_debug, ext_release, 'Build configuration list for PBXNativeTarget "QuietSafariExtension"'
    )
    blocker_list = config_list(
        project,
        blocker_debug,
        blocker_release,
        'Build configuration list for PBXNativeTarget "QuietSafariContentBlocker"',
    )
    privacy_list = config_list(
        project,
        privacy_debug,
        privacy_release,
        'Build configuration list for PBXNativeTarget "QuietSafariPrivacy"',
    )
    russian_list = config_list(
        project,
        russian_debug,
        russian_release,
        'Build configuration list for PBXNativeTarget "QuietSafariRussian"',
    )
    project_list = config_list(project, project_debug, project_release, "Build configuration list for PBXProject")

    # The project object id is reserved first so target proxies can point at it.
    project_id = project.add("PBXProject", "Project object", {})

    def proxy(remote_id: str, name: str) -> str:
        return project.add(
            "PBXContainerItemProxy",
            "PBXContainerItemProxy",
            {
                "containerPortal": project.ref(project_id, "Project object"),
                "proxyType": 1,
                "remoteGlobalIDString": Raw(remote_id),
                "remoteInfo": name,
            },
        )

    def dependency(remote_id: str, name: str) -> str:
        return project.add(
            "PBXTargetDependency",
            name,
            {
                "target": project.ref(remote_id, name),
                "targetProxy": project.ref(proxy(remote_id, name), "PBXContainerItemProxy"),
            },
        )

    ext_target = project.add(
        "PBXNativeTarget",
        "QuietSafariExtension",
        {
            "buildConfigurationList": project.ref(ext_list, "Build configuration list for PBXNativeTarget \"QuietSafariExtension\""),
            "buildPhases": [
                project.ref(ext_sources_phase, "Sources"),
                project.ref(ext_frameworks_phase, "Frameworks"),
                project.ref(ext_resources_phase, "Resources"),
            ],
            "buildRules": [],
            "dependencies": [],
            "name": "QuietSafariExtension",
            "productName": "QuietSafariExtension",
            "productReference": project.ref(ext_product, "QuietSafariExtension.appex"),
            "productType": "com.apple.product-type.app-extension",
        },
    )
    blocker_target = project.add(
        "PBXNativeTarget",
        "QuietSafariContentBlocker",
        {
            "buildConfigurationList": project.ref(
                blocker_list, 'Build configuration list for PBXNativeTarget "QuietSafariContentBlocker"'
            ),
            "buildPhases": [
                project.ref(blocker_sources_phase, "Sources"),
                project.ref(blocker_frameworks_phase, "Frameworks"),
                project.ref(blocker_resources_phase, "Resources"),
            ],
            "buildRules": [],
            "dependencies": [],
            "name": "QuietSafariContentBlocker",
            "productName": "QuietSafariContentBlocker",
            "productReference": project.ref(blocker_product, "QuietSafariContentBlocker.appex"),
            "productType": "com.apple.product-type.app-extension",
        },
    )
    russian_target = project.add(
        "PBXNativeTarget",
        "QuietSafariRussian",
        {
            "buildConfigurationList": project.ref(
                russian_list, 'Build configuration list for PBXNativeTarget "QuietSafariRussian"'
            ),
            "buildPhases": [
                project.ref(russian_sources_phase, "Sources"),
                project.ref(russian_frameworks_phase, "Frameworks"),
                project.ref(russian_resources_phase, "Resources"),
            ],
            "buildRules": [],
            "dependencies": [],
            "name": "QuietSafariRussian",
            "productName": "QuietSafariRussian",
            "productReference": project.ref(russian_product, "QuietSafariRussian.appex"),
            "productType": "com.apple.product-type.app-extension",
        },
    )
    privacy_target = project.add(
        "PBXNativeTarget",
        "QuietSafariPrivacy",
        {
            "buildConfigurationList": project.ref(
                privacy_list, 'Build configuration list for PBXNativeTarget "QuietSafariPrivacy"'
            ),
            "buildPhases": [
                project.ref(privacy_sources_phase, "Sources"),
                project.ref(privacy_frameworks_phase, "Frameworks"),
                project.ref(privacy_resources_phase, "Resources"),
            ],
            "buildRules": [],
            "dependencies": [],
            "name": "QuietSafariPrivacy",
            "productName": "QuietSafariPrivacy",
            "productReference": project.ref(privacy_product, "QuietSafariPrivacy.appex"),
            "productType": "com.apple.product-type.app-extension",
        },
    )
    app_target = project.add(
        "PBXNativeTarget",
        "QuietSafari",
        {
            "buildConfigurationList": project.ref(app_list, 'Build configuration list for PBXNativeTarget "QuietSafari"'),
            "buildPhases": [
                project.ref(app_sources_phase, "Sources"),
                project.ref(app_frameworks_phase, "Frameworks"),
                project.ref(app_resources_phase, "Resources"),
                project.ref(embed_phase, "Embed Foundation Extensions"),
            ],
            "buildRules": [],
            "dependencies": [
                project.ref(dependency(ext_target, "QuietSafariExtension"), "QuietSafariExtension"),
                project.ref(dependency(blocker_target, "QuietSafariContentBlocker"), "QuietSafariContentBlocker"),
                project.ref(dependency(privacy_target, "QuietSafariPrivacy"), "QuietSafariPrivacy"),
                project.ref(dependency(russian_target, "QuietSafariRussian"), "QuietSafariRussian"),
            ],
            "name": "QuietSafari",
            "productName": "QuietSafari",
            "productReference": project.ref(app_product, "QuietSafari.app"),
            "productType": "com.apple.product-type.application",
        },
    )

    # Fill the placeholder project object in place.
    replaced_project = False
    for index, (isa, identifier, comment, fields) in enumerate(project.objects):
        if identifier == project_id:
            replaced_project = True
            project.objects[index] = (
                isa,
                identifier,
                comment,
                {
                    "isa": "PBXProject",
                    "attributes": {
                        "BuildIndependentTargetsInParallel": True,
                        "LastUpgradeCheck": 1600,
                        "ORGANIZATIONNAME": "QuietSafari",
                        "TargetAttributes": {
                            Raw(app_target): {"CreatedOnToolsVersion": "16.0"},
                            Raw(ext_target): {"CreatedOnToolsVersion": "16.0"},
                            Raw(blocker_target): {"CreatedOnToolsVersion": "16.0"},
                            Raw(privacy_target): {"CreatedOnToolsVersion": "16.0"},
                            Raw(russian_target): {"CreatedOnToolsVersion": "16.0"},
                        },
                    },
                    "buildConfigurationList": project.ref(project_list, "Build configuration list for PBXProject"),
                    "compatibilityVersion": "Xcode 14.0",
                    "developmentRegion": "en",
                    "hasScannedForEncodings": 0,
                    "knownRegions": ["en", "Base"],
                    "mainGroup": project.ref(main_group, "QuietSafari"),
                    "productRefGroup": project.ref(products_group, "Products"),
                    "projectDirPath": "",
                    "projectRoot": "",
                    "targets": [
                        project.ref(app_target, "QuietSafari"),
                        project.ref(ext_target, "QuietSafariExtension"),
                        project.ref(blocker_target, "QuietSafariContentBlocker"),
                        project.ref(privacy_target, "QuietSafariPrivacy"),
                        project.ref(russian_target, "QuietSafariRussian"),
                    ],
                },
            )
            break
    if not replaced_project:
        raise SystemExit("project object was not filled in")

    order = [
        "PBXBuildFile",
        "PBXContainerItemProxy",
        "PBXCopyFilesBuildPhase",
        "PBXFileReference",
        "PBXFrameworksBuildPhase",
        "PBXGroup",
        "PBXNativeTarget",
        "PBXProject",
        "PBXResourcesBuildPhase",
        "PBXSourcesBuildPhase",
        "PBXTargetDependency",
        "XCBuildConfiguration",
        "XCConfigurationList",
    ]
    grouped: dict[str, list[tuple[str, str, dict]]] = {isa: [] for isa in order}
    defined = set()
    for isa, identifier, comment, fields in project.objects:
        if isa not in grouped:
            raise SystemExit(f"unexpected isa {isa}")
        if identifier in defined:
            raise SystemExit(f"duplicate id {identifier}")
        defined.add(identifier)
        grouped[isa].append((identifier, comment, fields))

    chunks = [
        "// !$*UTF8*$!",
        "{",
        "\tarchiveVersion = 1;",
        "\tclasses = {",
        "\t};",
        "\tobjectVersion = 56;",
        "\tobjects = {",
    ]
    for isa in order:
        entries = grouped[isa]
        if not entries:
            continue
        chunks.append(f"\n/* Begin {isa} section */")
        for identifier, comment, fields in entries:
            rendered = emit(fields, 2)
            chunks.append(f"\t\t{identifier} /* {comment} */ = {rendered};")
        chunks.append(f"/* End {isa} section */")
    chunks.append("\t};")
    chunks.append(f"\trootObject = {project_id} /* Project object */;")
    chunks.append("}")
    chunks.append("")
    pbx = "\n".join(chunks)
    scheme = scheme_text(app_target, ext_target, blocker_target, privacy_target, russian_target)
    workspace = """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""
    return pbx, scheme, workspace, {
        "app": app_target,
        "extension": ext_target,
        "blocker": blocker_target,
        "project": project_id,
    }


def scheme_text(app: str, extension: str, blocker: str, privacy: str, russian: str) -> str:
    def entry(identifier: str, name: str, product: str, testing: str = "YES") -> str:
        return f"""         <BuildActionEntry
            buildForTesting = "{testing}"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{identifier}"
               BuildableName = "{product}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:QuietSafari.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>"""

    app_ref = f"""            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app}"
               BuildableName = "QuietSafari.app"
               BlueprintName = "QuietSafari"
               ReferencedContainer = "container:QuietSafari.xcodeproj">
            </BuildableReference>"""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
{entry(extension, "QuietSafariExtension", "QuietSafariExtension.appex")}
{entry(blocker, "QuietSafariContentBlocker", "QuietSafariContentBlocker.appex")}
{entry(privacy, "QuietSafariPrivacy", "QuietSafariPrivacy.appex")}
{entry(russian, "QuietSafariRussian", "QuietSafariRussian.appex")}
{entry(app, "QuietSafari", "QuietSafari.app")}
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{app_ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{app_ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def check_references(pbx: str, ids: dict[str, str]) -> None:
    import re

    defined = set(re.findall(r"^\t\t([A-F0-9]{24}) ", pbx, flags=re.MULTILINE))
    mentioned = set(re.findall(r"\b([A-F0-9]{24})\b", pbx))
    missing = sorted(mentioned - defined)
    if missing:
        raise SystemExit("pbxproj references unknown ids: " + ", ".join(missing[:10]))
    if ids["project"] not in defined or f"rootObject = {ids['project']}" not in pbx:
        raise SystemExit("root object is not the project")
    for key in ("app", "extension", "blocker"):
        if ids[key] not in defined:
            raise SystemExit(f"missing target {key}")
    if "DEVELOPMENT_TEAM" in pbx:
        raise SystemExit("project must not pin a development team")


def main() -> None:
    pbx, scheme, workspace, ids = render()
    check_references(pbx, ids)
    if "--check" in sys.argv:
        current = {
            PBXPROJ: pbx,
            SCHEME: scheme,
            WORKSPACE: workspace,
        }
        mismatches = [str(path.relative_to(ROOT)) for path, text in current.items() if not path.exists() or path.read_text(encoding="utf-8") != text]
        if mismatches:
            raise SystemExit("xcodeproj is stale:\n" + "\n".join(mismatches))
        print("xcodeproj matches")
        return
    PBXPROJ.parent.mkdir(parents=True, exist_ok=True)
    SCHEME.parent.mkdir(parents=True, exist_ok=True)
    WORKSPACE.parent.mkdir(parents=True, exist_ok=True)
    PBXPROJ.write_text(pbx, encoding="utf-8")
    SCHEME.write_text(scheme, encoding="utf-8")
    WORKSPACE.write_text(workspace, encoding="utf-8")
    print(f"wrote {PBXPROJ.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
