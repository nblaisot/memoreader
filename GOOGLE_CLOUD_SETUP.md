# Google Cloud Setup Guide for Memoreader Sync

This guide will walk you through setting up Google Cloud project and OAuth credentials for Google Drive sync.

## Prerequisites

- A Google account
- Access to Google Cloud Console (free)

## Step 1: Create a Google Cloud Project

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Sign in with your Google account
3. Click the project dropdown at the top-left (next to "Google Cloud")
4. Click **"New Project"**
5. Enter project details:
   - **Project name**: `memoreader` (or any name you prefer)
   - **Organization**: Leave as default (or select if you have one)
   - **Location**: Leave as default
6. Click **"Create"**
7. Wait for the project to be created (may take a few seconds)
8. Select your new project from the project dropdown

## Step 2: Enable Google Drive API

1. In the left sidebar, go to **"APIs & Services"** > **"Library"**
2. In the search bar, type: **"Google Drive API"**
3. Click on **"Google Drive API"** in the results
4. Click the **"Enable"** button
5. Wait for the API to be enabled (may take a few seconds)

## Step 3: Configure OAuth Consent Screen

1. In the left sidebar, go to **"APIs & Services"** > **"OAuth consent screen"**
2. Select **"External"** user type (unless you're using Google Workspace for internal use only)
3. Click **"Create"**

### App Information:
- **App name**: `Memoreader` (or your preferred name)
- **User support email**: Your email address
- **App logo**: (Optional) Upload your app icon
- **App domain**: (Optional) Leave blank for now
- **Application home page**: (Optional) Your website if you have one
- **Privacy policy link**: (Optional) Your privacy policy URL
- **Terms of service link**: (Optional) Your terms of service URL
- **Authorized domains**: (Optional) Leave blank for now

4. Click **"Save and Continue"**

### Scopes:
1. Click **"Add or Remove Scopes"**
2. In the filter box, search for: `drive.appdata`
3. Check the box for: **`.../auth/drive.appdata`** (Google Drive API - Application data folder)
4. Click **"Update"**
5. Click **"Save and Continue"**

### Test Users (for development):
**⚠️ IMPORTANT: You MUST add test users or you'll get "Access blocked" errors!**

1. If you selected "External" user type, you'll need to add test users
2. Scroll down to the **"Test users"** section
3. Click **"+ ADD USERS"** button
4. Add your Google account email (the exact email you'll use to sign in, e.g., `nblaisot@gmail.com`)
5. Add any other test accounts you want to use
6. Click **"ADD"**
7. Click **"Save and Continue"** at the bottom of the page

### Summary:
1. Review the summary
2. Click **"Back to Dashboard"**

## Step 4: Create OAuth 2.0 Credentials

You'll need to create separate OAuth client IDs for each platform (iOS, Android, Web).

### For Android:

#### For Debug Build (Development):

1. In the left sidebar, go to **"APIs & Services"** > **"Credentials"**
2. Click **"+ CREATE CREDENTIALS"** > **"OAuth client ID"**
3. Select **"Android"** as the application type
4. Enter:
   - **Name**: `Memoreader Android Debug`
   - **Package name**: Check your `android/app/build.gradle.kts` file for `applicationId` (e.g., `com.blaisotbalette.memoreader`)
   - **SHA-1 certificate fingerprint**: 
     - Run: `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android`
     - Copy the SHA-1 value (looks like: `AA:BB:CC:DD:...`)
5. Click **"Create"**
6. **Copy the Client ID** - you'll need this for Android configuration

#### For Release Build (Production):

**Option A: Add Release SHA-1 to Existing Client ID (Recommended)**

1. Go to **"APIs & Services"** > **"Credentials"**
2. Find your existing Android OAuth Client ID (the one you created for debug)
3. Click the **pencil icon** (Edit) next to it
4. In the **"SHA-1 certificate fingerprints"** section, click **"+ ADD SHA-1 CERTIFICATE FINGERPRINT"**
5. Add your release SHA-1 fingerprint:
   - If you have a release keystore, run:
     ```bash
     keytool -list -v -keystore android/app/your_keystore.jks -alias your_key_alias
     ```
   - Copy the SHA-1 value and paste it
6. Click **"SAVE"**

**Option B: Create Separate Client ID for Release**

1. Click **"+ CREATE CREDENTIALS"** > **"OAuth client ID"** again
2. Select **"Android"** as the application type
3. Enter:
   - **Name**: `Memoreader Android Release`
   - **Package name**: Same as debug (e.g., `com.blaisotbalette.memoreader`)
   - **SHA-1 certificate fingerprint**: Your release keystore's SHA-1
4. Click **"Create"**
5. **Note**: If you use this option, you'll need to configure your app to use different Client IDs for debug vs release (see Step 5 below)

### For iOS:

1. Click **"+ CREATE CREDENTIALS"** > **"OAuth client ID"** again
2. Select **"iOS"** as the application type
3. Enter:
   - **Name**: `Memoreader iOS`
   - **Bundle ID**: Check your `ios/Runner.xcodeproj` or `ios/Runner/Info.plist` for `CFBundleIdentifier` (usually `com.example.memoreader` or similar)
4. Click **"Create"**
5. **Copy the Client ID** - you'll need this for iOS configuration

### For Web (optional, for Flutter web support):

1. Click **"+ CREATE CREDENTIALS"** > **"OAuth client ID"** again
2. Select **"Web application"** as the application type
3. Enter:
   - **Name**: `Memoreader Web`
   - **Authorized JavaScript origins**: 
     - `http://localhost:7357` (for Flutter web development)
     - Add your production domain if you have one
   - **Authorized redirect URIs**:
     - `http://localhost:7357` (for Flutter web development)
     - Add your production callback URL if you have one
4. Click **"Create"**
5. **Copy the Client ID** - you'll need this for web configuration

## Step 5: Configure Your Flutter App

### For Android:

#### If Using a Single Client ID (Option A from Step 4):

1. Open `android/app/src/main/res/values/strings.xml` (create it if it doesn't exist)
2. Add your Android Client ID:
   ```xml
   <string name="google_drive_client_id">YOUR_ANDROID_CLIENT_ID_HERE</string>
   ```
3. The AndroidManifest.xml is already configured to use this string resource

**Important:** Replace `YOUR_ANDROID_CLIENT_ID_HERE` with the actual Client ID you copied from Google Cloud Console.

#### If Using Separate Client IDs for Debug and Release (Option B from Step 4):

1. **Debug Client ID** - Open `android/app/src/main/res/values/strings.xml`:
   ```xml
   <string name="google_drive_client_id">YOUR_DEBUG_CLIENT_ID_HERE</string>
   ```

2. **Release Client ID** - Create `android/app/src/release/res/values/strings.xml`:
   ```xml
   <string name="google_drive_client_id">YOUR_RELEASE_CLIENT_ID_HERE</string>
   ```

3. The AndroidManifest.xml is already configured to use this string resource. Android will automatically use the appropriate Client ID based on the build type:
   - Debug builds use `src/main/res/values/strings.xml`
   - Release builds use `src/release/res/values/strings.xml` (overrides main)

**Important:** 
- Replace `YOUR_DEBUG_CLIENT_ID_HERE` with your debug Client ID
- Replace `YOUR_RELEASE_CLIENT_ID_HERE` with your release Client ID

### For iOS:

1. Open `ios/Runner/Info.plist`
2. Add your iOS Client ID:
```xml
<key>GOOGLE_SIGN_IN_CLIENT_ID</key>
<string>YOUR_IOS_CLIENT_ID_HERE</string>
```

### For Web (if supporting web):

1. Open `web/index.html`
2. Add your Web Client ID in the `<head>` section:
```html
<meta name="google-signin-client_id" content="YOUR_WEB_CLIENT_ID_HERE">
```

## Step 6: Update GoogleDriveSyncService (if needed)

The current implementation should work with the default `google_sign_in` configuration. However, if you need to specify client IDs explicitly, you can modify `lib/services/google_drive_sync_service.dart`:

```dart
final GoogleSignIn _googleSignIn = GoogleSignIn(
  scopes: [
    'https://www.googleapis.com/auth/drive.appdata',
  ],
  // Optionally specify client ID per platform:
  // clientId: 'YOUR_CLIENT_ID_HERE', // Usually not needed, auto-detected
);
```

## Step 7: Test the Setup

1. Run your Flutter app
2. Go to Settings
3. Enable "Google Drive Sync"
4. You should be prompted to sign in with Google
5. After signing in, sync should work

## Troubleshooting

### "Error 10: DEVELOPER_ERROR" (Android)
- Make sure your package name matches exactly
- Verify SHA-1 fingerprint is correct
- Ensure Google Drive API is enabled

### "Error 12500" (iOS)
- Verify Bundle ID matches exactly
- Check that OAuth consent screen is configured
- Ensure you're added as a test user (if app is in testing mode)

### "Access blocked" or "App not verified" (Error 403: access_denied)
- **This is the most common issue during development!**
- Your app is in "Testing" mode and your Google account is not added as a test user
- **Solution**: 
  1. Go to [OAuth consent screen](https://console.cloud.google.com/apis/credentials/consent)
  2. Scroll down to "Test users" section
  3. Click "+ ADD USERS"
  4. Add your Google account email (the one you're trying to sign in with)
  5. Click "ADD" and save
  6. Try signing in again in the app
- For production: Submit your app for verification (can take several days)

### "Quota exceeded"
- You're hitting the 12,000 requests/minute limit
- This is very unlikely for normal usage
- Implement exponential backoff (already done in the code)

## Important Notes

- **All OAuth Client IDs are public** - they're embedded in your app
- **No client secret needed** for mobile apps (only for server-side apps)
- **Each user signs in with their own Google account** - your project is just the app identifier
- **Storage uses user's Google Drive quota** (15GB free tier)
- **The appDataFolder is hidden** from users' normal Drive view

## Next Steps

After setup:
1. Test sync on one device
2. Test sync on a second device with the same Google account
3. Verify books, progress, and translations sync correctly
4. Test deletion and re-addition scenarios
5. Once verified, you can merge the branch to main

## Resources

- [Google Drive API Documentation](https://developers.google.com/drive/api)
- [Google Sign-In for Flutter](https://pub.dev/packages/google_sign_in)
- [OAuth 2.0 for Mobile Apps](https://developers.google.com/identity/protocols/oauth2/native-app)
