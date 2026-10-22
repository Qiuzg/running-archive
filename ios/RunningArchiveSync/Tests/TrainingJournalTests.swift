import Foundation

@main
struct TrainingJournalTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError("FAILED: \(message)") }
    }
    static func approximately(_ value: Double, _ expected: Double, _ message: String, tolerance: Double = 0.1) {
        check(abs(value - expected) < tolerance, "\(message): \(value) vs \(expected)")
    }
    static let start = Date(timeIntervalSince1970: 1_700_000_000)
    static func run(_ id: String, km: Double = 5, seconds: Double = 1500, date: Date = start) -> ArchiveActivity {
        ArchiveActivity(preview: WorkoutPreview(id: id, date: date, distanceKm: km, duration: seconds, avgHeartRate: 140, maxHeartRate: 170, avgPower: nil))
    }
    static func point(_ meters: Double, _ seconds: Double) -> RoutePointPayload {
        RoutePointPayload(timestamp: start.addingTimeInterval(seconds), latitude: 0, longitude: meters / 6_371_000 * 180 / .pi, altitude: 12, speedMps: nil)
    }
    static func route(_ id: String, coordinates: [[Double]], km: Double = 5) -> ArchiveRouteSummary {
        ArchiveRouteSummary(id: id, name: id, city: "", distanceKm: km, elevationGain: 0, previewCoordinates: coordinates)
    }

    @MainActor static func main() throws {
        let a = route("a", coordinates: [[121,31],[121.01,31.01],[121.02,31.02],[121.03,31.01],[121.04,31]])
        let b = route("b", coordinates: [[121.0001,31],[121.005,31.005],[121.0101,31.01],[121.0201,31.02],[121.0301,31.01],[121.0401,31]], km: 5.1)
        check(RouteMatcher.matches(a,b), "same shape with noise and different sampling density matches")
        check(!RouteMatcher.matches(a,route("reverse",coordinates: a.previewCoordinates.reversed())), "reverse direction rejected")
        check(!RouteMatcher.matches(a,route("distance",coordinates: a.previewCoordinates, km: 10)), "different lap distances rejected")
        check(!RouteMatcher.matches(a,route("different",coordinates: [[121,31],[121.02,30.98],[121.04,31]])), "same endpoints with different route rejected")
        check(!RouteMatcher.matches(a,route("invalid",coordinates: [[.nan,31],[999,999]])), "invalid coordinates rejected")
        let loop = route("loop",coordinates:[[121,31],[121.01,31],[121.01,31.02],[121,31.02],[121,31]])
        check(!RouteMatcher.matches(loop,route("loop-reversed",coordinates:loop.previewCoordinates.reversed())), "closed loop opposite directions rejected")

        let points = (0...600).map { point(Double($0) * 10, Double($0) * 2) }
        let efforts = BestEffortAnalyzer.analyze(points: points, start: start)
        check(efforts.count == 1 && efforts[0].distance == .five, "only complete distances emitted")
        approximately(efforts[0].seconds, 1000, "uniform 5K elapsed time")
        let pause = points.enumerated().map { index,p in
            RoutePointPayload(timestamp:p.timestamp.addingTimeInterval(index >= 300 ? 20 : 0),latitude:p.latitude,longitude:p.longitude,altitude:p.altitude,speedMps:nil)
        }
        approximately(BestEffortAnalyzer.analyze(points:pause,start:start)[0].seconds, 1020, "pause inside every 5K window included")
        let gap = points.enumerated().map { index,p in
            RoutePointPayload(timestamp:p.timestamp.addingTimeInterval(index >= 300 ? 130 : 0),latitude:p.latitude,longitude:p.longitude,altitude:p.altitude,speedMps:nil)
        }
        check(BestEffortAnalyzer.analyze(points:gap,start:start).isEmpty, "GPS gaps cannot be bridged to invent best efforts")
        var spike = points; spike[300] = point(50000,600)
        check(BestEffortAnalyzer.analyze(points:spike,start:start).isEmpty, "GPS teleport splits segments")
        check(BestEffortAnalyzer.analyze(points:[],start:start).isEmpty, "empty GPS safe")
        let long = (0...4300).map { point(Double($0)*10, Double($0)*2) }
        let longEfforts = BestEffortAnalyzer.analyze(points:long,start:start)
        check(longEfforts.count == 4, "all four target distances analyzed")
        approximately(longEfforts.first { $0.distance == .marathon }!.seconds, 8439, "interpolated marathon endpoint")
        let varied: [RoutePointPayload] = (0...1200).map { i in
            let meters = Double(i) * 10
            let elapsed: Double = i < 600 ? Double(i) * 3 : 1800 + Double(i - 600) * 2
            return point(meters, elapsed)
        }
        approximately(BestEffortAnalyzer.analyze(points:varied,start:start).first { $0.distance == .five }!.seconds,1000,"fastest window selected inside longer activity")

        let xml = try GPXExporter.document(name: "晨跑 & <滨江> \"路线\"", points: [points[10],points[0],points[20]])
        check(XMLParser(data: Data(xml.utf8)).parse(), "GPX is valid XML with escaped names")
        check(xml.contains("晨跑 &amp; &lt;滨江&gt; &quot;路线&quot;"), "GPX title escaped")
        check(xml.components(separatedBy:"<trkpt ").count - 1 == 3, "all raw points exported")
        check(xml.contains("<ele>12.00</ele>"), "altitude retained")
        let gapXML = try GPXExporter.document(name:"gap",points:gap)
        check(gapXML.components(separatedBy:"<trkseg>").count - 1 == 2, "GPX gap splits track segments")
        do { _ = try GPXExporter.document(name:"empty",points:[]); fatalError("empty GPX should fail") } catch JournalError.noRoute { checks += 1 }

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path:"journal.json")
        let journal = TrainingJournal(fileURL:url)
        var annotation = RunAnnotation(); annotation.kind = .tempo; annotation.effort = 7; annotation.note = "状态很好"; annotation.favoriteRoute = true; annotation.routeName = "滨江环线"
        check(journal.saveAnnotation(annotation,id:"a",now:start),"annotation saved")
        annotation.feedbackRecordedAt = start; annotation.feedbackUpdatedAt = start; annotation.noteUpdatedAt = start
        check(journal.setOverride(false,a:"a",b:"b"),"route correction saved")
        check(journal.override("b","a") == false,"route correction symmetric")
        let goal = RaceGoal(name:"春季半马",date:start,distanceKm:21.0975,targetSeconds:7200)
        check(journal.saveRace(goal),"race saved")
        var plan = PlannedRun(date:start,distanceKm:6,paceMin:290,paceMax:330,activityID:"a")
        check(journal.savePlan(plan),"plan saved")
        check(!journal.savePlan(PlannedRun(date:start,distanceKm:8,activityID:"a")),"activity cannot count toward two plans")
        check(journal.saveAnalysis(efforts,id:"a"),"efforts saved")
        let reloaded = TrainingJournal(fileURL:url)
        check(reloaded.annotation("a") == annotation,"annotation survives relaunch")
        check(reloaded.data.plans == [plan] && reloaded.data.races == [goal],"plans and race goals survive relaunch")
        check(reloaded.data.analyses["a"]?.efforts == efforts,"analysis survives relaunch")
        check(reloaded.override("b","a") == false,"override survives relaunch")
        check(plan.completion(activity:nil) == .missing,"missing HealthKit activity is not marked complete")
        check(plan.completion(activity:run("a",km:6,seconds:1800)) == .linked(distanceRatio:1,paceInRange:true),"distance and pace completion")
        check(plan.completion(activity:run("a",km:3,seconds:1200)) == .linked(distanceRatio:0.5,paceInRange:false),"partial distance and out-of-range pace")
        plan.activityID = nil
        check(plan.completion(activity:nil) == .unlinked,"unlinked plan has no invented completion")
        check(journal.savePlan(plan),"unlink saved")
        check(journal.savePlan(PlannedRun(date:start,distanceKm:8,activityID:"a")),"unlink releases activity")
        check(journal.deleteRace(goal.id) && journal.data.races.isEmpty,"delete goal")
        check(!journal.saveRace(RaceGoal(name:"",date:start,distanceKm:10)),"empty race name rejected")
        check(!journal.saveRace(RaceGoal(name:"bad",date:start,distanceKm:.nan)),"nonfinite distance rejected")
        check(!journal.savePlan(PlannedRun(date:start,distanceKm:5,paceMin:400,paceMax:300)),"inverted pace range rejected")
        check(!journal.savePlan(PlannedRun(date:start,distanceKm:5,paceMin:300,paceMax:nil)),"partial pace range rejected")
        annotation.effort = 11
        check(!journal.saveAnnotation(annotation,id:"bad"),"invalid effort rejected")
        check(TrainingFormat.parsePace("5:90") == nil && TrainingFormat.parsePace("5:30") == 330,"pace input validation")

        var state = JournalData()
        let runs = [run("short",km:4.9,seconds:1000),run("first",seconds:1600),run("pb",seconds:1500,date:start.addingTimeInterval(86400)),run("slow",seconds:1700,date:start.addingTimeInterval(172800)),run("tooLong",km:6,seconds:1400)]
        let records = RunRecord.history(activities:runs,category:.five,gps:false,journal:state)
        check(records.map(\.id) == ["first","pb","slow"],"whole run range does not scale underdistance or long activities")
        check(RunRecord.breakthroughs(records) == ["first","pb"],"record progression chronological")
        var excluded = RunAnnotation(); excluded.excludeFromRecords = true; state.annotations["pb"] = excluded
        check(RunRecord.history(activities:runs,category:.five,gps:false,journal:state).count == 2,"excluded records removed")
        state.analyses["tooLong"] = EffortAnalysis(analyzedAt:.now,efforts:efforts)
        check(RunRecord.history(activities:runs,category:.five,gps:true,journal:state).map(\.id) == ["tooLong"],"GPS records use analyses only")

        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:"America/Los_Angeles")!
        let beforeDST = calendar.date(from:DateComponents(year:2026,month:3,day:7,hour:23))!
        let raceDay = calendar.date(from:DateComponents(year:2026,month:3,day:9,hour:7))!
        check(RaceGoal(name:"test",date:raceDay,distanceKm:10).daysRemaining(now:beforeDST,calendar:calendar) == 2,"countdown uses calendar days across DST")
        let corrupt = Data("{broken".utf8); try corrupt.write(to:url)
        let broken = TrainingJournal(fileURL:url)
        check(!broken.saveAnnotation(RunAnnotation(),id:"x"),"corrupt file protected from overwrite")
        let retained = try Data(contentsOf:url)
        check(retained == corrupt,"original corrupt bytes preserved")
        print("Training journal tests passed: \(checks) checks")
    }
}
