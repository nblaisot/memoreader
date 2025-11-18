# App Store & Google Play Release Guide

This guide will help you prepare and submit Memoreader to both the Apple App Store and Google Play Store.

## 📋 Pre-Submission Checklist

### Before You Start

1. **Developer Accounts**
   - ✅ **Google Play**: Create account at [play.google.com/console](https://play.google.com/console) ($25 one-time fee)
   - ✅ **Apple App Store**: Enroll at [developer.apple.com](https://developer.apple.com) ($99/year)

2. **App Configuration Updates Needed**
   - ⚠️ **Android**: Change `applicationId` from `com.example.memoreader` to your unique ID (e.g., `com.yourname.memoreader`)
   - ⚠️ **iOS**: Configure proper Bundle Identifier in Xcode
   - ⚠️ **Both**: Set up code signing certificates
   - ⚠️ **Both**: Update app version in `pubspec.yaml` (currently `1.0.0+1`)

3. **App Metadata to Prepare**
   - App name (short and memorable)
   - Short description (80 chars for Google, 30 chars for Apple subtitle)
   - Full description (up to 4,000 characters)
   - Privacy policy URL (required for both stores)
   - Support email/website
   - App category (Books/Reading)

---

## 📸 Screenshot Requirements

### Google Play Store Screenshots

**Phone Screenshots:**
- **Minimum**: 2 screenshots
- **Maximum**: 8 screenshots
- **Format**: JPEG or 24-bit PNG (no alpha channel)
- **Dimensions**: 
  - Minimum: 320px (shortest side)
  - Maximum: 3840px (longest side)
  - Aspect ratio: Maximum dimension cannot be more than 2x the minimum
  - Common sizes: 1080x1920 (portrait) or 1920x1080 (landscape)

**Tablet Screenshots (Optional but Recommended):**
- **Minimum**: 2 screenshots
- **Maximum**: 8 screenshots
- **Format**: Same as phone
- **Dimensions**: 1200x1920 (portrait) or 1920x1200 (landscape)

**Recommended Screenshots to Take:**
1. Library view (showing books)
2. Reader view (showing text with pagination)
3. Settings screen
4. Import EPUB flow
5. Summary/Chapter view (if applicable)

### Apple App Store Screenshots

**iPhone Screenshots:**
- **Minimum**: 1 screenshot
- **Maximum**: 10 screenshots
- **Format**: JPEG or PNG
- **Required Sizes** (you need at least one set):
  - **iPhone 6.7" (iPhone 14 Pro Max, 15 Pro Max)**: 1290 x 2796 pixels
  - **iPhone 6.5" (iPhone 11 Pro Max, XS Max)**: 1242 x 2688 pixels
  - **iPhone 5.5" (iPhone 8 Plus)**: 1242 x 2208 pixels
  - **iPhone 4.7" (iPhone 8)**: 750 x 1334 pixels

**iPad Screenshots (if supporting iPad):**
- **Minimum**: 1 screenshot
- **Maximum**: 10 screenshots
- **Format**: JPEG or PNG
- **Required Sizes**:
  - **iPad Pro 12.9"**: 2048 x 2732 pixels
  - **iPad Pro 11"**: 1668 x 2388 pixels
  - **iPad (10.2")**: 1620 x 2160 pixels

**Note**: Apple will automatically scale your screenshots if you provide the highest resolution. Providing iPhone 6.7" screenshots will work for all iPhone sizes.

**Recommended Screenshots to Take:**
1. Library view (showing books)
2. Reader view (showing text with pagination)
3. Settings screen
4. Import EPUB flow
5. Summary/Chapter view (if applicable)

---

## 🎨 Visual Assets Required

### Google Play Store

1. **App Icon**
   - Size: 512 x 512 pixels
   - Format: 32-bit PNG (with alpha)
   - No transparency allowed (must have solid background)
   - Location: You have icons in `AppIcons/` folder

2. **Feature Graphic**
   - Size: 1024 x 500 pixels
   - Format: JPEG or 24-bit PNG
   - Used on the Play Store listing page
   - Should showcase your app's main features

3. **Promotional Graphic** (Optional)
   - Size: 180 x 120 pixels
   - Used for promotional placements

### Apple App Store

1. **App Icon**
   - Size: 1024 x 1024 pixels
   - Format: PNG or JPEG
   - No transparency, no rounded corners (Apple adds them)
   - Location: Check `AppIcons/Assets.xcassets/AppIcon.appiconset/`

2. **App Preview Videos** (Optional but recommended)
   - Up to 3 videos
   - 15-30 seconds each
   - Same sizes as screenshots

---

## 🚀 Step-by-Step Submission Process

### Google Play Store Submission

1. **Prepare Your App Bundle**
   ```bash
   flutter build appbundle --release
   ```
   This creates: `build/app/outputs/bundle/release/app-release.aab`

2. **Create App Listing**
   - Go to [Google Play Console](https://play.google.com/console)
   - Click "Create app"
   - Fill in:
     - App name: "MemoReader" (or your preferred name)
     - Default language: English
     - App or game: App
     - Free or paid: Free (or Paid)
     - Declarations: Check all that apply

3. **Set Up Store Listing**
   - **App details**:
     - Short description (80 chars max)
     - Full description (4000 chars max)
     - App icon (512x512)
     - Feature graphic (1024x500)
   - **Graphics**:
     - Upload phone screenshots (2-8)
     - Upload tablet screenshots if applicable (2-8)
   - **Categorization**:
     - App category: Books & Reference
     - Content rating: Complete questionnaire

4. **Content Rating**
   - Complete the questionnaire
   - Usually results in "Everyone" for a reading app

5. **Privacy Policy** (Required)
   - You must provide a privacy policy URL
   - Create a simple privacy policy page
   - Include what data you collect (if any)

6. **App Content**
   - Target audience
   - Data safety section (what data you collect/share)

7. **Pricing & Distribution**
   - Set price (Free or Paid)
   - Select countries
   - Device categories

8. **Upload App Bundle**
   - Go to "Production" (or "Internal testing" first)
   - Click "Create new release"
   - Upload the `.aab` file
   - Add release notes
   - Review and roll out

9. **Review Process**
   - Google typically reviews within 1-3 days
   - You'll receive email notifications

### Apple App Store Submission

1. **Prepare Your App**
   ```bash
   flutter build ipa --release
   ```
   Or build from Xcode:
   - Open `ios/Runner.xcworkspace` in Xcode
   - Select "Any iOS Device" as target
   - Product → Archive
   - Distribute App → App Store Connect

2. **App Store Connect Setup**
   - Go to [App Store Connect](https://appstoreconnect.apple.com)
   - Click "My Apps" → "+" → "New App"
   - Fill in:
     - Platform: iOS
     - Name: "MemoReader"
     - Primary language: English
     - Bundle ID: (must match your Xcode project)
     - SKU: Unique identifier (e.g., "memoreader-001")

3. **App Information**
   - **App Information**:
     - Category: Books
     - Subtitle (30 chars max)
     - Privacy Policy URL (required)
   - **Pricing and Availability**:
     - Set price (Free or Paid)
     - Select countries

4. **Version Information**
   - **What's New in This Version**: Release notes
   - **Description**: Up to 4,000 characters
   - **Keywords**: Comma-separated (100 chars max)
   - **Support URL**: Your website
   - **Marketing URL** (optional)

5. **App Preview and Screenshots**
   - Upload screenshots for each device size
   - At minimum, provide iPhone 6.7" screenshots
   - Add iPad screenshots if supporting iPad
   - Optional: Add app preview videos

6. **App Review Information**
   - Contact information
   - Demo account (if needed)
   - Notes for reviewer

7. **Version Release**
   - Choose automatic or manual release after approval

8. **Submit for Review**
   - Click "Submit for Review"
   - Answer export compliance questions
   - Review typically takes 24-48 hours

---

## 🔧 Configuration Changes Needed

### Android Configuration

1. **Update Application ID** in `android/app/build.gradle.kts`:
   ```kotlin
   applicationId = "com.yourname.memoreader"  // Change from com.example.memoreader
   ```

2. **Set Up Signing**:
   - Create a keystore file
   - Configure signing in `android/app/build.gradle.kts`
   - See Flutter's [signing guide](https://docs.flutter.dev/deployment/android#signing-the-app)

3. **Update App Name** in `android/app/src/main/AndroidManifest.xml`:
   ```xml
   android:label="MemoReader"  // Already set, but verify
   ```

### iOS Configuration

1. **Bundle Identifier**:
   - Open `ios/Runner.xcworkspace` in Xcode
   - Select Runner target → General tab
   - Update Bundle Identifier (e.g., `com.yourname.memoreader`)

2. **App Display Name**:
   - Already set in `Info.plist` as "Memoreader"
   - Can update if needed

3. **Signing & Capabilities**:
   - In Xcode, select your development team
   - Enable "Automatically manage signing"
   - Or manually configure certificates

---

## 📝 App Store Listing Content Template

### Short Description (Google Play - 80 chars)
```
Read EPUB books with AI-powered summaries and smart pagination
```

### Subtitle (Apple - 30 chars)
```
EPUB Reader with AI Summaries
```

### Full Description Template
```
MemoReader is a modern EPUB reader that makes reading digital books a pleasure.

KEY FEATURES:
• Beautiful, distraction-free reading experience
• Smart pagination that adapts to your screen
• AI-powered chapter summaries (OpenAI integration)
• Customizable text size and reading settings
• Library management with grid and list views
• Support for EPUB 2.0 and 3.0 formats
• Multi-language support (English, French)

PERFECT FOR:
• Book lovers who want a clean reading experience
• Students who need quick chapter summaries
• Anyone who reads digital books regularly

Import your EPUB files and start reading immediately. Customize your reading experience with adjustable text size, and use AI summaries to quickly understand chapter content.

Privacy-focused: Your books are stored locally on your device. AI summaries require internet connection and API configuration.

Download MemoReader today and transform your digital reading experience.
```

### Keywords (Apple - 100 chars)
```
epub,reader,books,ebook,reading,library,summaries,ai,openai
```

---

## ⚠️ Common Issues & Solutions

### Google Play Issues

1. **"App bundle is not signed"**
   - Solution: Set up proper signing configuration

2. **"Privacy policy required"**
   - Solution: Create a privacy policy page and add URL

3. **"Content rating incomplete"**
   - Solution: Complete the content rating questionnaire

### Apple App Store Issues

1. **"Missing compliance"**
   - Solution: Answer export compliance questions

2. **"Invalid bundle identifier"**
   - Solution: Ensure Bundle ID matches App Store Connect

3. **"Missing screenshots"**
   - Solution: Upload screenshots for at least one device size

4. **"App uses encryption"**
   - Solution: Answer "No" if you don't use encryption, or complete export compliance

---

## 🎯 Quick Start Checklist

- [ ] Create developer accounts (Google Play + Apple)
- [ ] Update application ID/bundle identifier
- [ ] Set up code signing (Android keystore + iOS certificates)
- [ ] Take screenshots (2-8 for Google, 1-10 for Apple)
- [ ] Prepare app icon (512x512 for Google, 1024x1024 for Apple)
- [ ] Create feature graphic (1024x500 for Google)
- [ ] Write app description and metadata
- [ ] Create privacy policy page
- [ ] Build release versions (`.aab` for Android, `.ipa` for iOS)
- [ ] Submit to stores
- [ ] Monitor review status

---

## 📚 Additional Resources

- [Flutter Deployment Guide](https://docs.flutter.dev/deployment)
- [Google Play Console Help](https://support.google.com/googleplay/android-developer)
- [Apple App Store Connect Help](https://help.apple.com/app-store-connect/)
- [Google Play Screenshot Specs](https://support.google.com/googleplay/android-developer/answer/1078870)
- [Apple Screenshot Specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/)

---

Good luck with your app release! 🚀

