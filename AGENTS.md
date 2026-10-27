# Pull Up repository guidance

**Identify the target before editing.** The App Store release is native iOS under `native/ios/`; the Expo/React Native app at the repository root is a legacy prototype. Do not implement native release requirements in the root `src/` app.

For native work, inspect `native/ios/project.yml`, `native/ios/Packages/PullUpKit/Package.swift`, `docs/RELEASE_CHECKLIST.md`, and the related CI workflows. Do not claim device tests or production readiness from simulator builds, source inspection or passing mocks. Preserve staging/production separation and RLS/authorization safeguards.

For **explicit legacy Expo prototype** changes only, read the exact versioned Expo documentation at https://docs.expo.dev/versions/v57.0.0/ before editing its code.

Do not merge release PRs, apply Supabase migrations, trigger a signed public distribution, incur new costs, accept agreements, or submit for App Review without the owner's explicit authorization. Prepare reviewable branches and label any blocked verification truthfully.
