//
//  AppDelegate.swift
//  AltStore
//
//  Created by Riley Testut on 5/9/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import UserNotifications
import AVFoundation
import Intents

import AltStoreCore
import AltSign
import Roxas

import Nuke

extension UIApplication: LegacyBackgroundFetching {}

extension AppDelegate
{
    static let openPatreonSettingsDeepLinkNotification = Notification.Name("com.rileytestut.AltStore.OpenPatreonSettingsDeepLinkNotification")
    static let importAppDeepLinkNotification = Notification.Name("com.rileytestut.AltStore.ImportAppDeepLinkNotification")
    static let addSourceDeepLinkNotification = Notification.Name("com.rileytestut.AltStore.AddSourceDeepLinkNotification")
    static let viewAppDeepLinkNotification = Notification.Name("com.rileytestut.AltStore.ViewAppDeepLinkNotification")
    static let searchDeepLinkNotification = Notification.Name("com.rileytestut.AltStore.SearchDeepLinkNotification")
    
    static let appBackupDidFinish = Notification.Name("com.rileytestut.AltStore.AppBackupDidFinish")
    
    static let importAppDeepLinkURLKey = "fileURL"
    static let appBackupResultKey = "result"
    static let addSourceDeepLinkURLKey = "sourceURL"
    static let viewAppDeepLinkStoreAppKey = "storeApp"
    static let searchDeepLinkQueryKey = "query"
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    
    private let intentHandler = IntentHandler()
    private let viewAppIntentHandler = ViewAppIntentHandler()
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        // Register default settings before doing anything else.
        UserDefaults.registerDefaults()
        
        DatabaseManager.shared.start { (error) in
            if let error = error
            {
                print("Failed to start DatabaseManager. Error:", error as Any)
            }
            else
            {
                print("Started DatabaseManager.")
            }
        }
        
        AnalyticsManager.shared.start()
        
        self.setTintColor()
        self.prepareImageCache()
        
        ServerManager.shared.startDiscovering()
        
        SecureValueTransformer.register()
        
        HTTPCookieStorage.migrateLocalPatreonCookiesIfNeeded()
        
        if UserDefaults.standard.firstLaunch == nil
        {
            Keychain.shared.reset()
            UserDefaults.standard.firstLaunch = Date()
        }
        
        UserDefaults.standard.preferredServerID = Bundle.main.object(forInfoDictionaryKey: Bundle.Info.serverID) as? String
        
        #if DEBUG || BETA
        UserDefaults.standard.isDebugModeEnabled = true
        #endif
        
        self.prepareForBackgroundFetch()
        
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication)
    {
        // Make sure to update SceneDelegate.sceneDidEnterBackground() as well.
        
        ServerManager.shared.stopDiscovering()
                
        guard let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date()) else { return }
        
        let midnightOneMonthAgo = Calendar.current.startOfDay(for: oneMonthAgo)
        DatabaseManager.shared.purgeLoggedErrors(before: midnightOneMonthAgo) { result in
            switch result
            {
            case .success: break
            case .failure(let error): print("[ALTLog] Failed to purge logged errors before \(midnightOneMonthAgo).", error)
            }
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication)
    {
        AppManager.shared.update()
        ServerManager.shared.startDiscovering()
        
        PatreonAPI.shared.refreshPatreonAccount()
    }
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any]) -> Bool
    {
        return self.open(url)
    }
    
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any?
    {
        switch intent
        {
        case is RefreshAllIntent: return self.intentHandler
        case is ViewAppIntent: return self.viewAppIntentHandler
        default: return nil
        }
    }
}

extension AppDelegate
{
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration
    {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
    
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>)
    {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
}

private extension AppDelegate
{
    func setTintColor()
    {
        self.window?.tintColor = .altPrimary
    }
    
    func prepareImageCache()
    {
        // Avoid caching responses twice.
        DataLoader.sharedUrlCache.diskCapacity = 0
        
        let pipeline = ImagePipeline { configuration in
            do
            {
                let dataCache = try DataCache(name: "io.altstore.Nuke")
                dataCache.sizeLimit = 512 * 1024 * 1024 // 512MB
                
                configuration.dataCache = dataCache
            }
            catch
            {
                Logger.main.error("Failed to create image disk cache. Falling back to URL cache. \(error.localizedDescription, privacy: .public)")
            }
        }
        
        ImagePipeline.shared = pipeline
        
        if let dataCache = ImagePipeline.shared.configuration.dataCache as? DataCache, #available(iOS 15, *)
        {
            Logger.main.info("Current image cache size: \(dataCache.totalSize.formatted(.byteCount(style: .file)), privacy: .public)")
        }
    }
    
    func open(_ url: URL) -> Bool
    {
        if AltStoreMCPURLHandler.shared.handle(url)
        {
            return true
        }
        
        if url.isFileURL
        {
            guard url.pathExtension.lowercased() == "ipa" else { return false }
            
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: url])
            }
            
            return true
        }
        else
        {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            guard let host = components.host?.lowercased() else { return false }
            
            switch host
            {
            case "patreon":
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.openPatreonSettingsDeepLinkNotification, object: nil)
                }
                
                return true
                
            case "appbackupresponse":
                let result: Result<Void, Error>
                
                switch url.path.lowercased()
                {
                case "/success": result = .success(())
                case "/failure":
                    let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
                    guard
                        let errorDomain = queryItems["errorDomain"],
                        let errorCodeString = queryItems["errorCode"], let errorCode = Int(errorCodeString),
                        let errorDescription = queryItems["errorDescription"]
                    else { return false }
                    
                    let error = NSError(domain: errorDomain, code: errorCode, userInfo: [NSLocalizedDescriptionKey: errorDescription])
                    result = .failure(error)
                    
                default: return false
                }
                
                NotificationCenter.default.post(name: AppDelegate.appBackupDidFinish, object: nil, userInfo: [AppDelegate.appBackupResultKey: result])
                
                return true
                
            case "install":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let downloadURLString = queryItems["url"], let downloadURL = URL(string: downloadURLString) else { return false }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: downloadURL])
                }
                
                return true
            
            case "source":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let sourceURLString = queryItems["url"], let sourceURL = URL(string: sourceURLString) else { return false }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.addSourceDeepLinkNotification, object: nil, userInfo: [AppDelegate.addSourceDeepLinkURLKey: sourceURL])
                }
                
                return true
                
            default: return false
            }
        }
    }
}

extension AppDelegate
{
    private func prepareForBackgroundFetch()
    {
        // "Fetch" every hour, but then refresh only those that need to be refreshed (so we don't drain the battery).
        (UIApplication.shared as LegacyBackgroundFetching).setMinimumBackgroundFetchInterval(1 * 60 * 60)
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { (success, error) in
        }
        
        #if DEBUG
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data)
    {
        let tokenParts = deviceToken.map { data -> String in
            return String(format: "%02.2hhx", data)
        }
        
        let token = tokenParts.joined()
        print("Push Token:", token)
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void)
    {
        self.application(application, performFetchWithCompletionHandler: completionHandler)
    }
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler backgroundFetchCompletionHandler: @escaping (UIBackgroundFetchResult) -> Void)
    {
        if UserDefaults.standard.isBackgroundRefreshEnabled && !UserDefaults.standard.presentedLaunchReminderNotification
        {
            let threeHours: TimeInterval = 3 * 60 * 60
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: threeHours, repeats: false)
            
            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("App Refresh Tip", comment: "")
            content.body = NSLocalizedString("The more you open AltStore, the more chances it's given to refresh apps in the background.", comment: "")
            
            let request = UNNotificationRequest(identifier: "background-refresh-reminder5", content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
            
            UserDefaults.standard.presentedLaunchReminderNotification = true
        }
        
        BackgroundTaskManager.shared.performExtendedBackgroundTask { (taskResult, taskCompletionHandler) in
            if let error = taskResult.error
            {
                print("Error starting extended background task. Aborting.", error)
                backgroundFetchCompletionHandler(.failed)
                taskCompletionHandler()
                return
            }
            
            if !DatabaseManager.shared.isStarted
            {
                DatabaseManager.shared.start() { (error) in
                    if error != nil
                    {
                        backgroundFetchCompletionHandler(.failed)
                        taskCompletionHandler()
                    }
                    else
                    {
                        self.performBackgroundFetch { (backgroundFetchResult) in
                            backgroundFetchCompletionHandler(backgroundFetchResult)
                        } refreshAppsCompletionHandler: { (refreshAppsResult) in
                            taskCompletionHandler()
                        }
                    }
                }
            }
            else
            {
                self.performBackgroundFetch { (backgroundFetchResult) in
                    backgroundFetchCompletionHandler(backgroundFetchResult)
                } refreshAppsCompletionHandler: { (refreshAppsResult) in
                    taskCompletionHandler()
                }
            }
        }
    }
    
    func performBackgroundFetch(backgroundFetchCompletionHandler: @escaping (UIBackgroundFetchResult) -> Void,
                                refreshAppsCompletionHandler: @escaping (Result<[String: Result<InstalledApp, Error>], Error>) -> Void)
    {
        self.fetchSources { (result) in
            switch result
            {
            case .failure: backgroundFetchCompletionHandler(.failed)
            case .success: backgroundFetchCompletionHandler(.newData)
            }
            
            if !UserDefaults.standard.isBackgroundRefreshEnabled
            {
                refreshAppsCompletionHandler(.success([:]))
            }
        }
        
        guard UserDefaults.standard.isBackgroundRefreshEnabled else { return }
        
        DatabaseManager.shared.persistentContainer.performBackgroundTask { (context) in
            let installedApps = InstalledApp.fetchAppsForBackgroundRefresh(in: context)
            AppManager.shared.backgroundRefresh(installedApps, completionHandler: refreshAppsCompletionHandler)
        }
    }
}

private extension AppDelegate
{
    func fetchSources(completionHandler: @escaping (Result<Set<Source>, Error>) -> Void)
    {
        AppManager.shared.fetchSources() { (result) in
            do
            {
                let (sources, context) = try result.get()
                
                let previousUpdatesFetchRequest = InstalledApp.supportedUpdatesFetchRequest() as! NSFetchRequest<NSFetchRequestResult>
                previousUpdatesFetchRequest.includesPendingChanges = false
                previousUpdatesFetchRequest.resultType = .dictionaryResultType
                previousUpdatesFetchRequest.propertiesToFetch = [#keyPath(InstalledApp.bundleIdentifier),
                                                                 #keyPath(InstalledApp.storeApp.latestSupportedVersion.version),
                                                                 #keyPath(InstalledApp.storeApp.latestSupportedVersion._buildVersion)]
                
                let previousNewsItemsFetchRequest = NewsItem.fetchRequest() as NSFetchRequest<NSFetchRequestResult>
                previousNewsItemsFetchRequest.includesPendingChanges = false
                previousNewsItemsFetchRequest.resultType = .dictionaryResultType
                previousNewsItemsFetchRequest.propertiesToFetch = [#keyPath(NewsItem.identifier)]
                
                let previousUpdates = try context.fetch(previousUpdatesFetchRequest) as! [[String: String]]
                let previousNewsItems = try context.fetch(previousNewsItemsFetchRequest) as! [[String: String]]
                
                try context.save()
                
                let updatesFetchRequest = InstalledApp.supportedUpdatesFetchRequest()
                let newsItemsFetchRequest = NewsItem.fetchRequest() as NSFetchRequest<NewsItem>
                
                let updates = try context.fetch(updatesFetchRequest)
                let newsItems = try context.fetch(newsItemsFetchRequest)
                
                for update in updates
                {
                    guard let storeApp = update.storeApp, let latestSupportedVersion = storeApp.latestSupportedVersion, latestSupportedVersion.isSupported else { continue }
                    
                    if let previousUpdate = previousUpdates.first(where: { $0[#keyPath(InstalledApp.bundleIdentifier)] == update.bundleIdentifier })
                    {
                        // An update for this app was already available, so check whether the version or build version is different.
                        guard let previousVersion = previousUpdate[#keyPath(InstalledApp.storeApp.latestSupportedVersion.version)] else { continue }
                        
                        // previousUpdate might not contain buildVersion, but if it does then map empty string to nil to match AppVersion.
                        var previousBuildVersion = previousUpdate[#keyPath(InstalledApp.storeApp.latestSupportedVersion._buildVersion)]
                        if previousBuildVersion == ""
                        {
                            previousBuildVersion = nil
                        }
                        
                        // Only show notification if previous latestSupportedVersion does not _exactly_ match current latestSupportedVersion.
                        guard previousVersion != latestSupportedVersion.version || previousBuildVersion != latestSupportedVersion.buildVersion  else { continue }
                    }
                    
                    let content = UNMutableNotificationContent()
                    content.title = NSLocalizedString("New Update Available", comment: "")
                    content.body = String(format: NSLocalizedString("%@ %@ is now available for download.", comment: ""), update.name, latestSupportedVersion.localizedVersion)
                    content.sound = .default
                    
                    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request)
                }
                
                for newsItem in newsItems
                {
                    guard !previousNewsItems.contains(where: { $0[#keyPath(NewsItem.identifier)] == newsItem.identifier }) else { continue }
                    guard !newsItem.isSilent else { continue }
                    
                    let content = UNMutableNotificationContent()
                    
                    if let app = newsItem.storeApp
                    {
                        content.title = String(format: NSLocalizedString("%@ News", comment: ""), app.name)
                    }
                    else
                    {
                        content.title = NSLocalizedString("AltStore News", comment: "")
                    }
                    
                    content.body = newsItem.title
                    content.sound = .default
                    
                    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                    UNUserNotificationCenter.current().add(request)
                }

                DispatchQueue.main.async {
                    UNUserNotificationCenter.current().setBadgeCount(updates.count) { error in
                        guard let error else { return }
                        Logger.main.error("Failed to update app icon badge count. \(error.localizedDescription, privacy: .public)")
                    }
                }
                
                completionHandler(.success(sources))
            }
            catch
            {
                print("Error fetching apps:", error)
                completionHandler(.failure(error))
            }
        }
    }
}


// MARK: - AltStore MCP URL Handling

final class AltStoreMCPURLHandler
{
    static let shared = AltStoreMCPURLHandler()
    
    private init() {}
    
    func handle(_ url: URL) -> Bool
    {
        guard let scheme = url.scheme?.lowercased(), scheme == "altstore-mcp" else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        guard components.host?.lowercased() == "x-callback-url" else { return false }
        
        let pathComponents = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard let actionComponent = pathComponents.first else
        {
            Task { await self.sendUnsupportedAction(nil, context: XCallbackContext(components: components)) }
            return true
        }
        
        let action = actionComponent.lowercased()
        let context = XCallbackContext(components: components)
        
        switch action
        {
        case "sync-sources":
            Task(priority: .userInitiated) {
                Logger.main.info("altstore-mcp handling action: sync-sources (state: \(context.state ?? "none"), success: \(context.successURL?.absoluteString ?? "nil"))")
                await self.handleSyncSources(context: context)
            }
            
        default:
            Task {
                await self.sendUnsupportedAction(action, context: context)
            }
        }
        
        return true
    }
}

private extension AltStoreMCPURLHandler
{
    func handleSyncSources(context: XCallbackContext) async
    {
        do
        {
            Logger.main.info("altstore-mcp sync-sources: refreshing sources…")
            try await self.updateAllSources()

            #if MARKETPLACE
            if #available(iOS 17.4, *)
            {
                await AppMarketplace.shared.update()
            }
            #endif

            Logger.main.info("altstore-mcp sync-sources: building result metadata…")
            let metadata = try await self.makeSyncResult()
            await self.presentResultAlert(.success(metadata), context: context)
        }
        catch
        {
            Logger.main.error("altstore-mcp sync-sources failed. \(error.localizedDescription, privacy: .public)")
            await self.presentResultAlert(.failure(error), context: context)
        }
    }
    
    func updateAllSources() async throws
    {
        try await withCheckedThrowingContinuation { continuation in
            AppManager.shared.updateAllSources { result in
                continuation.resume(with: result)
            }
        }
    }
    
    func makeSyncResult() async throws -> SourceSyncResult
    {
        try await withCheckedThrowingContinuation { continuation in
            DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
                do
                {
                    let sources = Source.all(in: context)
                        .map { SourceSyncResult.SourceSummary(identifier: $0.identifier, name: $0.name) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    
                    let updatesFetchRequest = InstalledApp.supportedUpdatesFetchRequest()
                    let updates = try context.fetch(updatesFetchRequest)
                    let updateSummaries = updates.compactMap { (installedApp) -> SourceSyncResult.AppUpdate? in
                        guard let storeApp = installedApp.storeApp, let latestVersion = storeApp.latestSupportedVersion else { return nil }
                        
                        let sourceIdentifier = storeApp.source?.identifier
                        let sourceName = storeApp.source?.name
                        
                        return SourceSyncResult.AppUpdate(bundleIdentifier: installedApp.bundleIdentifier,
                                                          name: installedApp.name,
                                                          version: latestVersion.version,
                                                          build: latestVersion.buildVersion,
                                                          sourceIdentifier: sourceIdentifier,
                                                          sourceName: sourceName)
                    }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let timestamp = formatter.string(from: Date())
                    
                    let result = SourceSyncResult(completedAt: timestamp,
                                                  sourcesRefreshed: sources.count,
                                                  updatesAvailable: updateSummaries.count,
                                                  sources: sources,
                                                  updates: updateSummaries)
                    
                    continuation.resume(returning: result)
                }
                catch
                {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func sendSuccess(metadata: SourceSyncResult, context: XCallbackContext) async throws
    {
        guard let callbackURL = context.successURL else
        {
            Logger.main.info("altstore-mcp sync-sources completed without x-success callback.")
            return
        }
        
        let queryItems = try self.successQueryItems(for: metadata, state: context.state)
        await self.open(callbackURL, appending: queryItems)
    }
    
    func sendFailure(error: Error, context: XCallbackContext) async
    {
        guard let callbackURL = context.errorURL ?? context.failureURL else
        {
            Logger.main.error("altstore-mcp sync-sources failed without x-error callback. \(error.localizedDescription, privacy: .public)")
            return
        }

        do
        {
            let metadata = await self.failureMetadata(from: error)
            let queryItems = try self.failureQueryItems(for: metadata, state: context.state)
            await self.open(callbackURL, appending: queryItems)
        }
        catch
        {
            Logger.main.error("altstore-mcp sync-sources failed to encode error metadata. \(error.localizedDescription, privacy: .public)")
        }
    }

    enum SyncAlertResult
    {
        case success(SourceSyncResult)
        case failure(Error)
    }

    func presentResultAlert(_ result: SyncAlertResult, context: XCallbackContext) async
    {
        await MainActor.run {
            Logger.main.info("altstore-mcp sync-sources preparing UI for \(context.state ?? "unknown state")")
        }
        if let presenter = await self.presenterForMyApps()
        {
            await self.presentResultAlert(on: presenter, result: result, context: context)
        }
        else
        {
            Logger.main.error("altstore-mcp sync-sources unable to obtain presenter; invoking callback immediately.")
            switch result
            {
            case .success(let metadata):
                try? await self.sendSuccess(metadata: metadata, context: context)
            case .failure(let error):
                await self.sendFailure(error: error, context: context)
            }
        }
    }

    @MainActor
    func presenterForMyApps() async -> UIViewController?
    {
        for attempt in 0..<10
        {
            if let root = await self.rootViewController(),
               let tabBarController = self.findTabBarController(from: root)
            {
                if let presenter = await self.prepareTabBarForMyApps(tabBarController)
                {
                    if attempt > 0
                    {
                        Logger.main.info("altstore-mcp sync-sources obtained presenter after \(attempt + 1) attempts")
                    }
                    return presenter
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms grace while tab bar initializes
        }
        return nil
    }

    @MainActor
    func prepareTabBarForMyApps(_ tabBarController: UITabBarController) async -> UIViewController?
    {
        if let presented = tabBarController.presentedViewController
        {
            await withCheckedContinuation { continuation in
                tabBarController.dismiss(animated: true) {
                    continuation.resume(returning: ())
                }
            }
            return nil
        }

        let myAppsIndex = 3
        if let count = tabBarController.viewControllers?.count, count > myAppsIndex
        {
            tabBarController.selectedIndex = myAppsIndex
        }
        
        guard let selectedController = tabBarController.selectedViewController else { return tabBarController }
        if let navigationController = selectedController as? UINavigationController
        {
            return navigationController.topViewController ?? navigationController
        }
        return selectedController
    }

    @MainActor
    func findTabBarController(from viewController: UIViewController?) -> UITabBarController?
    {
        if let tabBar = viewController as? UITabBarController { return tabBar }
        if let navigationController = viewController as? UINavigationController
        {
            return self.findTabBarController(from: navigationController.viewControllers.first)
        }
        if let presented = viewController?.presentedViewController
        {
            return self.findTabBarController(from: presented)
        }
        for child in viewController?.children ?? []
        {
            if let tabBar = self.findTabBarController(from: child) { return tabBar }
        }
        return nil
    }

    @MainActor
    func rootViewController() -> UIViewController?
    {
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { [.foregroundActive, .foregroundInactive, .background].contains($0.activationState) }),
           let window = windowScene.windows.first(where: { $0.isKeyWindow })
        {
            return window.rootViewController
        }
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
           let root = appDelegate.window?.rootViewController
        {
            return root
        }
        return nil
    }

    @MainActor
    func presentResultAlert(on presenter: UIViewController, result: SyncAlertResult, context: XCallbackContext) async
    {
        let alertTitle: String
        let alertMessage: String
        let continueAction: (() -> Void)?
        
        switch result
        {
        case .success(let metadata):
            alertTitle = NSLocalizedString("Sources Synced", comment: "")
            alertMessage = String(format: NSLocalizedString("Refreshed %d sources. %d apps have updates.", comment: ""), metadata.sourcesRefreshed, metadata.updatesAvailable)
            if context.successURL != nil
            {
                continueAction = { [weak self] in
                    guard let self else { return }
                    Task {
                        do { try await self.sendSuccess(metadata: metadata, context: context) }
                        catch { Logger.main.error("altstore-mcp sync-sources could not invoke success callback. \(error.localizedDescription, privacy: .public)") }
                    }
                }
            }
            else
            {
                continueAction = nil
            }
            Logger.main.info("altstore-mcp sync-sources success: sources=\(metadata.sourcesRefreshed), updates=\(metadata.updatesAvailable)")
        case .failure(let error):
            alertTitle = NSLocalizedString("Sync Failed", comment: "")
            alertMessage = error.localizedDescription
            if (context.errorURL ?? context.failureURL) != nil
            {
                continueAction = { [weak self] in
                    guard let self else { return }
                    Task { await self.sendFailure(error: error, context: context) }
                }
            }
            else
            {
                continueAction = nil
            }
            Logger.main.error("altstore-mcp sync-sources failure alert: \(error.localizedDescription, privacy: .public)")
        }
        
        let alertController = UIAlertController(title: alertTitle, message: alertMessage, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Stay in AltStore", comment: ""), style: .cancel))
        if let continueAction
        {
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Continue on Lu", comment: ""), style: .default) { _ in
                Logger.main.info("altstore-mcp sync-sources continue on Lu selected.")
                continueAction()
            })
        }
        else
        {
            Logger.main.info("altstore-mcp sync-sources no continuation callback available.")
        }
        presenter.present(alertController, animated: true)
    }
    
    func sendUnsupportedAction(_ action: String?, context: XCallbackContext) async
    {
        let message: String
        if let action, !action.isEmpty
        {
            message = String(format: NSLocalizedString("AltStore cannot handle the action \"%@\".", comment: ""), action)
        }
        else
        {
            message = NSLocalizedString("AltStore could not determine which action to perform.", comment: "")
        }
        
        let error = NSError(domain: "AltStoreMCP", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        await self.sendFailure(error: error, context: context)
    }
    
    func open(_ url: URL, appending queryItems: [URLQueryItem]) async
    {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var items = components.queryItems ?? []
        items.append(contentsOf: queryItems)
        components.queryItems = items
        guard let finalURL = components.url else { return }
        
        await MainActor.run {
            UIApplication.shared.open(finalURL, options: [:], completionHandler: nil)
        }
    }
    
    func successQueryItems(for metadata: SourceSyncResult, state: String?) throws -> [URLQueryItem]
    {
        var queryItems = [URLQueryItem(name: "status", value: "success")]
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        let json = String(decoding: data, as: UTF8.self)
        queryItems.append(URLQueryItem(name: "result", value: json))
        
        if let state
        {
            queryItems.append(URLQueryItem(name: "state", value: state))
        }
        
        return queryItems
    }
    
    func failureQueryItems(for metadata: SourceSyncFailure, state: String?) throws -> [URLQueryItem]
    {
        var queryItems = [
            URLQueryItem(name: "status", value: "error"),
            URLQueryItem(name: "errorCode", value: metadata.code),
            URLQueryItem(name: "errorMessage", value: metadata.message)
        ]
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        let json = String(decoding: data, as: UTF8.self)
        queryItems.append(URLQueryItem(name: "metadata", value: json))
        
        if let state
        {
            queryItems.append(URLQueryItem(name: "state", value: state))
        }
        
        return queryItems
    }
    
    func failureMetadata(from error: Error) async -> SourceSyncFailure
    {
        if let fetchError = error as? AppManager.FetchSourcesError
        {
            return await self.failureMetadata(from: fetchError)
        }
        else
        {
            let nsError = error as NSError
            let code = "\(nsError.domain)#\(nsError.code)"
            let message = nsError.localizedDescription
            let details = nsError.localizedFailureReason ?? nsError.localizedRecoverySuggestion
            return SourceSyncFailure(code: code, message: message, details: details, failedSources: nil)
        }
    }
    
    func failureMetadata(from error: AppManager.FetchSourcesError) async -> SourceSyncFailure
    {
        var failedSources = [SourceSyncFailure.FailedSource]()
        error.managedObjectContext?.performAndWait {
            failedSources = error.errors.map { (source, sourceError) in
                SourceSyncFailure.FailedSource(identifier: source.identifier,
                                               name: source.name,
                                               message: sourceError.localizedDescription)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        
        let message = error.errorDescription ?? NSLocalizedString("Unable to Refresh Store", comment: "")
        let details = error.primaryError?.localizedDescription
        return SourceSyncFailure(code: "fetch_sources_error",
                                 message: message,
                                 details: details,
                                 failedSources: failedSources.isEmpty ? nil : failedSources)
    }
}

private struct XCallbackContext
{
    let successURL: URL?
    let errorURL: URL?
    let failureURL: URL?
    let cancelURL: URL?
    let state: String?
    
    init(components: URLComponents)
    {
        var values = [String: String]()
        components.queryItems?.forEach { item in
            guard let value = item.value else { return }
            values[item.name.lowercased()] = value
        }
        
        self.successURL = values["x-success"].flatMap(URL.init)
        self.errorURL = values["x-error"].flatMap(URL.init)
        self.failureURL = values["x-failure"].flatMap(URL.init)
        self.cancelURL = values["x-cancel"].flatMap(URL.init)
        self.state = values["state"]
    }
}

private struct SourceSyncResult: Codable
{
    struct SourceSummary: Codable
    {
        let identifier: String
        let name: String
    }
    
    struct AppUpdate: Codable
    {
        let bundleIdentifier: String
        let name: String
        let version: String
        let build: String?
        let sourceIdentifier: String?
        let sourceName: String?
    }
    
    let completedAt: String
    let sourcesRefreshed: Int
    let updatesAvailable: Int
    let sources: [SourceSummary]
    let updates: [AppUpdate]
}

private struct SourceSyncFailure: Codable
{
    struct FailedSource: Codable
    {
        let identifier: String
        let name: String
        let message: String
    }
    
    let code: String
    let message: String
    let details: String?
    let failedSources: [FailedSource]?
}
