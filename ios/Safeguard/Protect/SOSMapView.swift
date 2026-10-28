import CoreLocation
import MapKit
import SwiftUI

struct SOSMapView: View {
    let fix: CLLocation?
    let places: [SOSPlace]
    let route: MKRoute?
    let destination: CLLocationCoordinate2D?
    let destinationName: String?

    @State private var position: MapCameraPosition = .automatic

    private var framingKey: String {
        let you = fix.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" } ?? "-"
        let there = destination.map { "\($0.latitude),\($0.longitude)" } ?? "-"
        return "\(you)|\(there)|\(places.count)|\(route != nil)"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Map(position: $position, interactionModes: [.pan, .zoom, .rotate]) {
                if let fix {
                    if fix.horizontalAccuracy > 8 {
                        MapCircle(center: fix.coordinate, radius: fix.horizontalAccuracy)
                            .foregroundStyle(.blue.opacity(0.14))
                            .stroke(.blue.opacity(0.4), lineWidth: 1)
                    }
                    Annotation("You", coordinate: fix.coordinate, anchor: .center) {
                        YouDot()
                    }
                }
                ForEach(places) { place in
                    Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
                        PlacePin(kind: place.kind, highlighted: isDestination(place))
                    }
                }
                if let route {
                    MapPolyline(route.polyline)
                        .stroke(
                            LinearGradient(
                                colors: [.blue, DS.Colors.ok],
                                startPoint: .leading, endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                        )
                }
            }
            .mapStyle(.standard(
                elevation: .flat,
                emphasis: .muted,
                pointsOfInterest: .including([.police, .hospital, .pharmacy]),
                showsTraffic: false
            ))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            Button {
                refit(animated: true)
            } label: {
                Image(systemName: "scope")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .safeguardCircle()
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel("Re-centre the map")
        }
        .onAppear { refit(animated: false) }
        .onChange(of: framingKey) { _, _ in refit(animated: true) }
    }

    private func isDestination(_ place: SOSPlace) -> Bool {
        guard let destination else { return false }
        return abs(place.coordinate.latitude - destination.latitude) < 0.00002
            && abs(place.coordinate.longitude - destination.longitude) < 0.00002
    }

    private func refit(animated: Bool) {
        var points: [CLLocationCoordinate2D] = []
        if let fix { points.append(fix.coordinate) }
        if let destination { points.append(destination) }
        if destination == nil { points.append(contentsOf: places.prefix(2).map(\.coordinate)) }
        guard let rect = MapFraming.rect(covering: points, minimumMeters: 600) else { return }
        let apply = { position = .rect(rect) }
        if animated {
            withAnimation(DS.Motion.smooth, apply)
        } else {
            apply()
        }
    }
}

private struct YouDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var halo = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.blue.opacity(0.25))
                .frame(width: 44, height: 44)
                .scaleEffect(halo ? 1 : 0.5)
                .opacity(halo ? 0 : 1)
            Circle().fill(.white).frame(width: 22, height: 22)
            Circle().fill(.blue).frame(width: 16, height: 16)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                halo = true
            }
        }
        .accessibilityLabel("Your location")
    }
}

private struct PlacePin: View {
    let kind: SOSPlaceKind
    let highlighted: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(kind == .police ? Color.blue : Color.red)
                .frame(width: highlighted ? 40 : 30, height: highlighted ? 40 : 30)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            Image(systemName: kind.symbol)
                .font(.system(size: highlighted ? 18 : 14, weight: .bold))
                .foregroundStyle(.white)
        }
        .animation(DS.Motion.snappy, value: highlighted)
        .accessibilityLabel(kind == .police ? "Police station" : "Hospital")
    }
}
