# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Loupe is a native macOS (SwiftUI) Kubernetes cluster browser — a Lens/k9s-style GUI that talks to the
Kubernetes API directly. It shells out to no CLI: not `kubectl`, not `helm`. The only external binary it
uses is `openssl` (for client-certificate auth) and whatever credential plugin a kubeconfig names.

## Commands

Requires Xcode 26.2+ (project `objectVersion = 77`, deployment target macOS 26.2).

```bash
xcodebuild -project loupe.xcodeproj -scheme loupe -configuration Debug -destination 'platform=macOS' build
```

```bash
xcodebuild -resolvePackageDependencies -project loupe.xcodeproj -scheme loupe
```

Package the built app as a .dmg the same way CI does (reproduces packaging problems without pushing a tag):

```bash
scripts/make-dmg.sh path/to/loupe.app dist/Loupe-1.2.3.dmg "Loupe 1.2.3"
```

Cutting a release is `git tag v1.2.3 && git push origin v1.2.3`, which runs
[.github/workflows/release.yml](.github/workflows/release.yml) (archive → sign → notarize → .dmg → GitHub
release). Without the signing secrets it still succeeds, producing an ad-hoc signed build.

**There are no tests and no test target.** The scheme's `TestAction` is empty. Adding tests means adding a
new target to the project, which the file-system-synchronized group below will *not* do for you.

## Project structure quirks

- `loupe/` is a `PBXFileSystemSynchronizedRootGroup`. Any `.swift` file placed anywhere under it is
  compiled automatically — never edit `project.pbxproj` to add or move sources. The flip side: a stray or
  half-finished `.swift` file left under `loupe/` breaks the build.
- The `JSONValue.swift`, `YAML.swift` and `main.swift` at the **repository root are stale scratch copies**
  outside the target — `main.swift` no longer even compiles against them. The canonical sources are
  `loupe/Core/`. Edit those; leave the root files alone.
- Build settings that are deliberate, not accidents: the app sandbox is **off** and hardened runtime is on
  (it reads `~/.kube/config` and spawns credential plugins); App Transport Security is disabled in
  [Supporting/Info.plist](Supporting/Info.plist) because cluster certs come from private CAs that the app
  validates itself in `KubeSessionDelegate`.
- Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, so `@MainActor` is always
  explicit on the models.
- The one package dependency is SwiftTerm (pod shell). swift-argument-parser comes in transitively.

## Architecture

Four layers, bottom-up: `Core/` → `Kube/` → `App/` → `UI/`.

**The central design decision is that nothing is codegen'd or `Codable`.** Objects stay unstructured
`JSONValue` end to end, and lists are fetched through the API server's Table representation. That is what
lets the app browse *any* kind a cluster serves — CRDs included — with the same columns `kubectl get`
prints, without knowing anything about it in advance. Preserve that property when adding features.

### Core — [loupe/Core](loupe/Core)

`JSONValue`/`JSONObject` preserve key order and the literal spelling of numbers, so the YAML tab shows
`apiVersion, kind, metadata, spec, status` in the server's order and a large `resourceVersion` survives a
round trip. `YAMLParser` covers only the subset kubeconfigs and manifests use (no anchors, aliases, or
tags) — that is intentional. `Quantity` parses/formats Kubernetes quantities (`250m`, `1Gi`).

### Kube — [loupe/Kube](loupe/Kube)

- `KubeClient` — dynamic HTTP client over paths + `JSONValue`. Unary requests, newline-delimited streams
  (`lines`, used for watches and logs), and WebSockets (exec, attach, port-forward). `canI(verb:…)` runs a
  SelfSubjectAccessReview so the UI can hide actions that would 403.
- `KubeConfig` — parses and merges the files `KUBECONFIG` names, resolving a context to a `KubeTarget`.
- `KubeCredentials` — an actor resolving auth headers, caching exec-plugin tokens until expiry. Credential
  plugins are located on `PATH` plus the Homebrew paths a GUI app doesn't inherit.
- `KubeTLS` — pins to the kubeconfig CA rather than the system trust store. Client certs are converted to
  a `SecIdentity` by packaging them into a throwaway PKCS#12 via `openssl`, deliberately never writing to
  the user's keychain.
- `APIResource`/`APIDiscovery`/`APICatalog` — aggregated discovery (k8s 1.27+) with a fallback to the
  per-group walk. `APIResource.stableKey` (`apps.v1.deployments`) is the identity used for sidebar entries
  and persisted navigation state.
- `KubeObject` — the unstructured wrapper, with the health derivation (`ResourceHealth`) that drives row
  tinting, plus `ResourceTable`/`WatchEvent` decoding.
- `PortForward` — implements the multiplexed WebSocket forward protocol directly; one WebSocket per
  inbound TCP connection, as kubectl does.

### App — [loupe/App](loupe/App)

`AppModel` (`@MainActor @Observable`) owns the kubeconfig and a list of `ClusterConnection`s — **several
clusters are open at once**, each with its own `KubeClient` and `URLSession`. A `ClusterConnection` holds
discovery results, the namespace filter, cluster metrics, and a `generation` counter so a superseded slow
connect cannot write final state. Metrics come from `metrics.k8s.io` or, for clusters without
metrics-server, from Prometheus — see `MetricsSettings` (persisted per context) and `Kube/Prometheus.swift`,
which reaches Prometheus through the API server's service proxy so no second credential is needed.

`NavigationCatalog.build` turns live discovery into the sidebar: known (group, plural) pairs land in fixed
categories in a fixed order, and everything else — CRDs the app has never seen — is grouped by API group
under "Custom Resources", so nothing in the cluster is unreachable.

`ResourceListModel` lists one resource type and then watches it: paged list via `KubeAccept.table`, then a
watch from the returned `resourceVersion`, restarting on 410. Note the graceful-degradation path — a
cluster-wide list refused with 403 falls back to walking the namespaces in scope, and the watch is then
scoped the same way.

`ResourceActions` holds every mutation (delete, replace, scale, rollout restart, suspend, cordon, drain,
trigger CronJob). `drain` deliberately reports evictions the API server refuses (PodDisruptionBudget
rejections) rather than counting them as success.

### UI — [loupe/UI](loupe/UI)

SwiftUI throughout, `NavigationSplitView` with a right-hand `ObjectInspector` (Overview / YAML / Events /
Logs / Shell). `LogsView` streams either one pod or every pod behind a controller (`WorkloadPods` resolves
the fan-out), merging the lines on the kubelet's timestamps; logs can also detach into their own
`WindowGroup`, restorable across launches.

- `ResourceTableView` is drawn by hand rather than with SwiftUI `Table`, because the columns are only
  known at runtime.
- **To add a kind-specific detail view**: write a `…Sections` view in
  [KindSections.swift](loupe/UI/Detail/KindSections.swift), add a `case` to the `switch object.kind` in
  [ObjectOverview.swift:96](loupe/UI/Detail/ObjectOverview.swift:96), and optionally an icon in
  `NavigationCatalog.iconsByKind`. Nothing else needs registering — the kind is already browsable.
- `HelmReleasesView` reads Helm v3 releases straight out of `helm.sh/release.v1` Secrets (gzipped JSON,
  base64'd twice), which is what the CLI does, so no helm binary or cluster component is needed.

### Conventions

- Persisted UI state lives in `UserDefaults` under `loupe.`-prefixed keys (`loupe.openContexts`,
  `loupe.activeContext`, `loupe.selectedNamespaces`, `loupe.selections`).
- Models are `@MainActor @Observable`; long-lived `Task`s that must be cancelled from `deinit` are held as
  `@ObservationIgnored nonisolated(unsafe)`.
- Errors reach the UI as strings through `ClusterConnection.describe(_:)`, and are surfaced with the
  shared `Banner` / `EmptyStateView` widgets rather than per-view alert plumbing (`ActionRunner` wraps the
  do/catch for mutations).
- Comments in this codebase explain *why*, especially where a workaround is load-bearing (the PKCS#12
  dance, ATS being off, the hand-drawn table). Match that: don't strip those comments, and write in the
  same register.
