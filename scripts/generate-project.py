#!/usr/bin/env python3
"""Reproducible dependency-free Xcode project generation."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(value): return '"' + str(value).replace('"', '\\"') + '"'
objects = []
def obj(name, body):
    ident = uid(name)
    objects.append(f'{ident} = {{ {body} }};')
    return ident
def seq(items): return '(' + ', '.join(items) + (',' if items else '') + ')'
sources = sorted(root.glob('GravelFit/**/*.swift'))
tests = sorted(root.glob('GravelFitTests/*.swift'))
resources = [root / 'GravelFit/Resources/PrivacyInfo.xcprivacy']
asset = root / 'GravelFit/Resources/Assets.xcassets'
if asset.exists(): resources.append(asset)
refs = {}
for file in sources + tests + resources + [root/'GravelFit/Resources/Info.plist', root/'GravelFit/Resources/GravelFit.entitlements']:
    path = str(file.relative_to(root))
    typ = 'sourcecode.swift' if file.suffix == '.swift' else 'folder.assetcatalog' if file.suffix == '.xcassets' else 'text.plist.xml'
    refs[path] = obj('ref:'+path, f'isa = PBXFileReference; lastKnownFileType = {typ}; path = {q(path)}; sourceTree = SOURCE_ROOT;')
def build_refs(target, files):
    return [obj(target+':'+str(f), f'isa = PBXBuildFile; fileRef = {refs[str(f.relative_to(root))]};') for f in files]
app_sources = obj('app sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {seq(build_refs("app", sources))}; runOnlyForDeploymentPostprocessing = 0;')
# Standalone tests compile production code without the @main entry point or camera capture.
test_sources = [f for f in sources if f.name != 'GravelFitApp.swift']
test_phase = obj('test sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {seq(build_refs("tests", tests + test_sources))}; runOnlyForDeploymentPostprocessing = 0;')
app_resources = obj('app resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {seq(build_refs("resources", resources))}; runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
app_product = obj('app product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = GravelFit.app; sourceTree = BUILT_PRODUCTS_DIR;')
test_product = obj('test product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = GravelFitTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', f'isa = PBXGroup; children = {seq([app_product,test_product])}; name = Products; sourceTree = "<group>";')
main_group = obj('main group', f'isa = PBXGroup; children = {seq(list(refs.values())+[products])}; sourceTree = "<group>";')
def config_list(target):
    ids = []
    for mode in ['Debug','Release']:
        settings = {'MACOSX_DEPLOYMENT_TARGET':'15.0', 'SDKROOT':'macosx', 'SWIFT_VERSION':'6.0', 'SWIFT_STRICT_CONCURRENCY':'complete', 'CLANG_ENABLE_MODULES':'YES', 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode == 'Debug' else '-O', 'DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym', 'ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO', 'CODE_SIGN_STYLE':'Automatic', 'CODE_SIGN_IDENTITY':'-', 'PRODUCT_NAME':'$(TARGET_NAME)'}
        if target == 'app': settings.update({'PRODUCT_BUNDLE_IDENTIFIER':'com.gravelfit.app', 'INFOPLIST_FILE':'GravelFit/Resources/Info.plist','CODE_SIGN_ENTITLEMENTS':'GravelFit/Resources/GravelFit.entitlements', 'ENABLE_APP_SANDBOX':'YES','ENABLE_HARDENED_RUNTIME':'YES','CODE_SIGN_INJECT_BASE_ENTITLEMENTS':'YES' if mode == 'Debug' else 'NO','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks'})
        elif target == 'tests': settings.update({'PRODUCT_BUNDLE_IDENTIFIER':'com.gravelfit.tests', 'GENERATE_INFOPLIST_FILE':'YES','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @loader_path/../Frameworks @executable_path/../Frameworks'})
        else: settings = {'MACOSX_DEPLOYMENT_TARGET':'15.0', 'SDKROOT':'macosx', 'SWIFT_VERSION':'6.0','CLANG_ENABLE_MODULES':'YES'}
        body = ' '.join(f'{k} = {q(v)};' for k,v in settings.items())
        ids.append(obj(target+mode, f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {mode};'))
    return obj(target+' configs', f'isa = XCConfigurationList; buildConfigurations = {seq(ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
app = obj('app target', f'isa = PBXNativeTarget; buildConfigurationList = {config_list("app")}; buildPhases = {seq([app_sources,frameworks,app_resources])}; buildRules = (); dependencies = (); name = GravelFit; productName = GravelFit; productReference = {app_product}; productType = "com.apple.product-type.application";')
test = obj('test target', f'isa = PBXNativeTarget; buildConfigurationList = {config_list("tests")}; buildPhases = {seq([test_phase])}; buildRules = (); dependencies = (); name = GravelFitTests; productName = GravelFitTests; productReference = {test_product}; productType = "com.apple.product-type.bundle.unit-test";')
project = obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {config_list("project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {main_group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {seq([app,test])};')
project_dir = root/'GravelFit.xcodeproj'
project_dir.mkdir(exist_ok=True)
(project_dir/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
scheme_dir=project_dir/'xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True,exist_ok=True)
def ref(ident,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:GravelFit.xcodeproj"/>'
(scheme_dir/'GravelFit.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(app,'GravelFit.app')}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{ref(test,'GravelFitTests.xctest')}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test,'GravelFitTests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app,'GravelFit.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app,'GravelFit.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated GravelFit.xcodeproj')
