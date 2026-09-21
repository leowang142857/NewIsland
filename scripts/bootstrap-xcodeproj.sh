#!/usr/bin/env bash
# Recreate GrokIsland.xcodeproj next to the GrokIsland sources.
# Run from anywhere: ./scripts/bootstrap-xcodeproj.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/GrokIsland.xcodeproj"
SCHEME_DIR="$PROJ/xcshareddata/xcschemes"

if [[ ! -d "$ROOT/GrokIsland" ]]; then
  echo "error: expected $ROOT/GrokIsland" >&2
  exit 1
fi

mkdir -p "$SCHEME_DIR"

cat > "$PROJ/project.pbxproj" <<'EOF'
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
		01C000000000000000000001 /* GrokIslandApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000001 /* GrokIslandApp.swift */; };
		01C000000000000000000002 /* Models.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000002 /* Models.swift */; };
		01C000000000000000000003 /* RunModels.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000003 /* RunModels.swift */; };
		01C000000000000000000004 /* ModuleStore.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000004 /* ModuleStore.swift */; };
		01C000000000000000000005 /* ResourceInbox.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000005 /* ResourceInbox.swift */; };
		01C000000000000000000006 /* ResourceIntake.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000006 /* ResourceIntake.swift */; };
		01C000000000000000000007 /* ExecutorProtocol.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000007 /* ExecutorProtocol.swift */; };
		01C000000000000000000008 /* LocalExecutor.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000008 /* LocalExecutor.swift */; };
		01C000000000000000000009 /* GrokBotExecutor.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000009 /* GrokBotExecutor.swift */; };
		01C00000000000000000000A /* RunJournal.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B00000000000000000000A /* RunJournal.swift */; };
		01C00000000000000000000B /* ExecutionRouter.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B00000000000000000000B /* ExecutionRouter.swift */; };
		01C00000000000000000000C /* IslandEngine.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B00000000000000000000C /* IslandEngine.swift */; };
		01C00000000000000000000D /* IslandPanel.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B00000000000000000000D /* IslandPanel.swift */; };
		01C00000000000000000000E /* ShellView.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B00000000000000000000E /* ShellView.swift */; };
		01C000000000000000000012 /* DesktopShortcut.swift in Sources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000012 /* DesktopShortcut.swift */; };
		01C000000000000000000011 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = 01B000000000000000000011 /* Assets.xcassets */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		01A000000000000000000003 /* GrokIsland.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = GrokIsland.app; sourceTree = BUILT_PRODUCTS_DIR; };
		01B000000000000000000001 /* GrokIslandApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GrokIslandApp.swift; sourceTree = "<group>"; };
		01B000000000000000000002 /* Models.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Models.swift; sourceTree = "<group>"; };
		01B000000000000000000003 /* RunModels.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RunModels.swift; sourceTree = "<group>"; };
		01B000000000000000000004 /* ModuleStore.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ModuleStore.swift; sourceTree = "<group>"; };
		01B000000000000000000005 /* ResourceInbox.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ResourceInbox.swift; sourceTree = "<group>"; };
		01B000000000000000000006 /* ResourceIntake.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ResourceIntake.swift; sourceTree = "<group>"; };
		01B000000000000000000007 /* ExecutorProtocol.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ExecutorProtocol.swift; sourceTree = "<group>"; };
		01B000000000000000000008 /* LocalExecutor.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LocalExecutor.swift; sourceTree = "<group>"; };
		01B000000000000000000009 /* GrokBotExecutor.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = GrokBotExecutor.swift; sourceTree = "<group>"; };
		01B00000000000000000000A /* RunJournal.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RunJournal.swift; sourceTree = "<group>"; };
		01B00000000000000000000B /* ExecutionRouter.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ExecutionRouter.swift; sourceTree = "<group>"; };
		01B00000000000000000000C /* IslandEngine.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = IslandEngine.swift; sourceTree = "<group>"; };
		01B00000000000000000000D /* IslandPanel.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = IslandPanel.swift; sourceTree = "<group>"; };
		01B00000000000000000000E /* ShellView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ShellView.swift; sourceTree = "<group>"; };
		01B000000000000000000012 /* DesktopShortcut.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DesktopShortcut.swift; sourceTree = "<group>"; };
		01B00000000000000000000F /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		01B000000000000000000010 /* GrokIsland.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = GrokIsland.entitlements; sourceTree = "<group>"; };
		01B000000000000000000011 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		01A000000000000000000012 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		01A000000000000000000020 /* Core */ = {
			isa = PBXGroup;
			children = (
				01B000000000000000000002 /* Models.swift */,
				01B000000000000000000003 /* RunModels.swift */,
				01B000000000000000000004 /* ModuleStore.swift */,
				01B000000000000000000005 /* ResourceInbox.swift */,
				01B000000000000000000006 /* ResourceIntake.swift */,
				01B000000000000000000007 /* ExecutorProtocol.swift */,
				01B000000000000000000008 /* LocalExecutor.swift */,
				01B000000000000000000009 /* GrokBotExecutor.swift */,
				01B00000000000000000000A /* RunJournal.swift */,
				01B00000000000000000000B /* ExecutionRouter.swift */,
				01B00000000000000000000C /* IslandEngine.swift */,
			);
			name = Core;
			sourceTree = "<group>";
		};
		01A000000000000000000021 /* Products */ = {
			isa = PBXGroup;
			children = (
				01A000000000000000000003 /* GrokIsland.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
		01A000000000000000000022 /* GrokIsland */ = {
			isa = PBXGroup;
			children = (
				01B000000000000000000001 /* GrokIslandApp.swift */,
				01B00000000000000000000D /* IslandPanel.swift */,
				01B00000000000000000000E /* ShellView.swift */,
				01B000000000000000000012 /* DesktopShortcut.swift */,
				01A000000000000000000020 /* Core */,
				01B00000000000000000000F /* Info.plist */,
				01B000000000000000000010 /* GrokIsland.entitlements */,
				01B000000000000000000011 /* Assets.xcassets */,
			);
			path = GrokIsland;
			sourceTree = "<group>";
		};
		01A000000000000000000023 = {
			isa = PBXGroup;
			children = (
				01A000000000000000000022 /* GrokIsland */,
				01A000000000000000000021 /* Products */,
			);
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		01A000000000000000000002 /* GrokIsland */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 01A000000000000000000031 /* Build configuration list for PBXNativeTarget "GrokIsland" */;
			buildPhases = (
				01A000000000000000000010 /* Sources */,
				01A000000000000000000012 /* Frameworks */,
				01A000000000000000000011 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = GrokIsland;
			productName = GrokIsland;
			productReference = 01A000000000000000000003 /* GrokIsland.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		01A000000000000000000001 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {
					01A000000000000000000002 = {
						CreatedOnToolsVersion = 15.0;
					};
				};
			};
			buildConfigurationList = 01A000000000000000000030 /* Build configuration list for PBXProject "GrokIsland" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
				"zh-Hans",
			);
			mainGroup = 01A000000000000000000023;
			productRefGroup = 01A000000000000000000021 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				01A000000000000000000002 /* GrokIsland */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		01A000000000000000000011 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				01C000000000000000000011 /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		01A000000000000000000010 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				01C000000000000000000001 /* GrokIslandApp.swift in Sources */,
				01C000000000000000000002 /* Models.swift in Sources */,
				01C000000000000000000003 /* RunModels.swift in Sources */,
				01C000000000000000000004 /* ModuleStore.swift in Sources */,
				01C000000000000000000005 /* ResourceInbox.swift in Sources */,
				01C000000000000000000006 /* ResourceIntake.swift in Sources */,
				01C000000000000000000007 /* ExecutorProtocol.swift in Sources */,
				01C000000000000000000008 /* LocalExecutor.swift in Sources */,
				01C000000000000000000009 /* GrokBotExecutor.swift in Sources */,
				01C00000000000000000000A /* RunJournal.swift in Sources */,
				01C00000000000000000000B /* ExecutionRouter.swift in Sources */,
				01C00000000000000000000C /* IslandEngine.swift in Sources */,
				01C00000000000000000000D /* IslandPanel.swift in Sources */,
				01C00000000000000000000E /* ShellView.swift in Sources */,
				01C000000000000000000012 /* DesktopShortcut.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		01A000000000000000000040 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_OPTIMIZATION_LEVEL = 0;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		01A000000000000000000041 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
			};
			name = Release;
		};
		01A000000000000000000042 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = GrokIsland/GrokIsland.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = NO;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = GrokIsland/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = "grok岛";
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities";
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = app.grokisland.GrokIsland;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		01A000000000000000000043 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = GrokIsland/GrokIsland.entitlements;
				CODE_SIGN_IDENTITY = "-";
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = NO;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = GrokIsland/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = "grok岛";
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities";
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = app.grokisland.GrokIsland;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		01A000000000000000000030 /* Build configuration list for PBXProject "GrokIsland" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				01A000000000000000000040 /* Debug */,
				01A000000000000000000041 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		01A000000000000000000031 /* Build configuration list for PBXNativeTarget "GrokIsland" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				01A000000000000000000042 /* Debug */,
				01A000000000000000000043 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = 01A000000000000000000001 /* Project object */;
}
EOF

cat > "$SCHEME_DIR/GrokIsland.xcscheme" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "01A000000000000000000002"
               BuildableName = "GrokIsland.app"
               BlueprintName = "GrokIsland"
               ReferencedContainer = "container:GrokIsland.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
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
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "01A000000000000000000002"
            BuildableName = "GrokIsland.app"
            BlueprintName = "GrokIsland"
            ReferencedContainer = "container:GrokIsland.xcodeproj">
         </BuildableReference>
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
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "01A000000000000000000002"
            BuildableName = "GrokIsland.app"
            BlueprintName = "GrokIsland"
            ReferencedContainer = "container:GrokIsland.xcodeproj">
         </BuildableReference>
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
EOF

chmod +x "$0" 2>/dev/null || true
echo "Wrote $PROJ"
echo "Open with:  open \"$PROJ\""
