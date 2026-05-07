# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Uncomment this to preserve the line number information for
# debugging stack traces.
#-keepattributes SourceFile,LineNumberTable

# If you keep the line number information, uncomment this to
# hide the original source file name.
#-renamesourcefileattribute SourceFile
# 混合时不使用大小写混合，混合后的类名为小写
-dontusemixedcaseclassnames

# 这句话能够使我们的项目混淆后产生映射文件
# 包含有类名->混淆后类名的映射关系
-verbose

# 保留Annotation不混淆
-keepattributes *Annotation*,InnerClasses

# 避免混淆泛型
-keepattributes Signature

# 指定混淆是采用的算法，后面的参数是一个过滤器
# 这个过滤器是谷歌推荐的算法，一般不做更改
-optimizations !code/simplification/cast,!field/*,!class/merging/*

-flattenpackagehierarchy

#############################################
#
# Android开发中一些需要保留的公共部分
#
#############################################
# 屏蔽错误Unresolved class name
#noinspection ShrinkerUnresolvedReference

# 移除Log类打印各个等级日志的代码，打正式包的时候可以做为禁log使用，这里可以作为禁止log打印的功能使用
# 记得proguard-android.txt中一定不要加-dontoptimize才起作用
# 另外的一种实现方案是通过BuildConfig.DEBUG的变量来控制
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int i(...);
    public static int w(...);
    public static int d(...);
    public static int e(...);
}

# 保持js引擎调用的java类
-keep class * extends io.legado.app.help.JsExtensions{*;}
# 数据类
-keep class **.data.entities.**{*;}
# hutool-core hutool-crypto
-keep class
!cn.hutool.core.util.RuntimeUtil,
!cn.hutool.core.util.ClassLoaderUtil,
!cn.hutool.core.util.ReflectUtil,
!cn.hutool.core.util.SerializeUtil,
!cn.hutool.core.util.ClassUtil,
cn.hutool.core.codec.**,
cn.hutool.core.util.**{*;}
-keep class cn.hutool.crypto.**{*;}
-dontwarn cn.hutool.**
# 缓存 Cookie
-keep class **.help.http.CookieStore{*;}
-keep class **.help.CacheManager{*;}
# StrResponse
-keep class **.help.http.StrResponse{*;}

# markwon
-dontwarn org.commonmark.ext.gfm.**

-keep class okhttp3.*{*;}
-keep class okio.*{*;}
-keep class com.jayway.jsonpath.*{*;}

# LiveEventBus
-keepclassmembers class androidx.lifecycle.LiveData {
    *** mObservers;
    *** mActiveCount;
}
-keepclassmembers class androidx.arch.core.internal.SafeIterableMap {
    *** size();
    *** putIfAbsent(...);
}

## ChangeBookSourceDialog initNavigationView
-keepclassmembers class androidx.appcompat.widget.Toolbar {
    *** mNavButtonView;
}

# MenuExtensions applyOpenTint
-keepnames class androidx.appcompat.view.menu.SubMenuBuilder
-keep class androidx.appcompat.view.menu.MenuBuilder {
    *** setOptionalIconsVisible(...);
    *** getNonActionItems();
}

# FileDocExtensions.kt treeDocumentFileConstructor
-keep class androidx.documentfile.provider.TreeDocumentFile {
    <init>(...);
}

# JsoupXpath
-keep,allowobfuscation class * implements org.seimicrawler.xpath.core.AxisSelector{*;}
-keep,allowobfuscation class * implements org.seimicrawler.xpath.core.NodeTest{*;}
-keep,allowobfuscation class * implements org.seimicrawler.xpath.core.Function{*;}

## JSOUP
-keep class org.jsoup.**{*;}
-dontwarn org.jspecify.annotations.NullMarked

## ExoPlayer 反射设置ua 保证该私有变量不被混淆
-keepclassmembers class androidx.media3.datasource.cache.CacheDataSource$Factory {
    *** upstreamDataSourceFactory;
}
## ExoPlayer 如果还不能播放就取消注释这个
# -keep class com.google.android.exoplayer2.** {*;}

## 对外提供api
-keep class io.legado.app.api.ReturnData{*;}

# Cronet
-keepclassmembers class org.chromium.net.X509Util {
    *** sDefaultTrustManager;
    *** sTestTrustManager;
}

# Throwable
-keepnames class * extends java.lang.Throwable
-keepclassmembernames,allowobfuscation class * extends java.lang.Throwable{*;}

# 万象书屋: CSJ/YLH SDK R8 missing rules (auto-generated)
# Please add these rules to your existing keep rules in order to suppress warnings.
# This is generated automatically by the Android Gradle plugin.
-dontwarn android.app.Activity$TranslucentConversionListener
-dontwarn android.os.SystemProperties
-dontwarn com.bytedance.component.sdk.annotation.AnyThread
-dontwarn com.bytedance.component.sdk.annotation.CallSuper
-dontwarn com.bytedance.component.sdk.annotation.ColorInt
-dontwarn com.bytedance.component.sdk.annotation.DungeonFlag
-dontwarn com.bytedance.component.sdk.annotation.FloatRange
-dontwarn com.bytedance.component.sdk.annotation.HungeonFlag
-dontwarn com.bytedance.component.sdk.annotation.IntRange
-dontwarn com.bytedance.component.sdk.annotation.Keep
-dontwarn com.bytedance.component.sdk.annotation.MainThread
-dontwarn com.bytedance.component.sdk.annotation.RawRes
-dontwarn com.bytedance.component.sdk.annotation.RequiresApi
-dontwarn com.bytedance.component.sdk.annotation.RestrictTo$Scope
-dontwarn com.bytedance.component.sdk.annotation.RestrictTo
-dontwarn com.bytedance.component.sdk.annotation.UiThread
-dontwarn com.bytedance.component.sdk.annotation.WorkerThread
-dontwarn com.bytedance.embed_dr.OaidVivoImpl$Type
-dontwarn com.bytedance.framwork.core.sdkmonitor.SDKMonitor$IGetExtendParams
-dontwarn com.bytedance.framwork.core.sdkmonitor.SDKMonitor
-dontwarn com.bytedance.framwork.core.sdkmonitor.SDKMonitorUtils
-dontwarn com.bytedance.keva.Keva
-dontwarn com.bytedance.keva.KevaBuilder
-dontwarn com.bytedance.keva.KevaMonitor
-dontwarn com.bytedance.sdk.openadsdk.TTDownloadEventLogger
-dontwarn com.bytedance.sdk.openadsdk.downloadnew.core.DialogBuilder
-dontwarn com.bytedance.sdk.openadsdk.downloadnew.core.IDialogStatusChangedListener
-dontwarn com.bytedance.sdk.openadsdk.downloadnew.core.ITTDownloadAdapter$OnEventLogHandler
-dontwarn com.bytedance.sdk.openadsdk.downloadnew.core.ITTDownloadVisitor
-dontwarn com.bytedance.sdk.openadsdk.downloadnew.core.ITTHttpCallback
-dontwarn com.bytedance.sdk.openadsdk.downloadnew.core.ITTPermissionCallback
-dontwarn com.bytedance.sdk.openadsdk.downloadnew.core.TTDownloadEventModel
-dontwarn com.google.android.gms.ads.identifier.AdvertisingIdClient$Info
-dontwarn com.google.android.gms.ads.identifier.AdvertisingIdClient
-dontwarn org.apache.commons.net.ntp.NTPUDPClient
-dontwarn org.apache.commons.net.ntp.NtpV3Packet
-dontwarn org.apache.commons.net.ntp.TimeInfo
-dontwarn org.apache.commons.net.ntp.TimeStamp
