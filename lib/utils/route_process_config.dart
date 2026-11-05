import 'package:latlong2/latlong.dart';

enum RouteProcessType {
  twoGroupStaged,       // Guinsang-an, Lindero (Dalipe Direct + Robinsons Call)
  scheduledTwoGroup,    // Dao (Robinsons only, schedule)
  scheduledSingleGroup, // Anini-y (Dalipe, schedule)
  fcfsTimer,            // Sibalom (FCFS + timer)
  fcfsPure,             // Belison, Patnongon, Bugasong, San Remigio (FCFS when full)
}

class RouteProcessInfo {
  final String routeId;
  final String displayName;
  final RouteProcessType processType;
  final List<String> ownerCoopIds;
  final LatLng destinationCoords;

  const RouteProcessInfo({
    required this.routeId,
    required this.displayName,
    required this.processType,
    required this.ownerCoopIds,
    required this.destinationCoords,
  });

  bool get isRotationRoute =>
      processType == RouteProcessType.twoGroupStaged ||
      processType == RouteProcessType.scheduledTwoGroup ||
      processType == RouteProcessType.scheduledSingleGroup;

  bool get isPureFcfs => processType == RouteProcessType.fcfsPure;
}

class RouteRegistry {
  static const Map<String, RouteProcessInfo> routes = {
    'ROUTE_GUINSANGAN': RouteProcessInfo(
      routeId: 'ROUTE_GUINSANGAN',
      displayName: 'San Jose - Guinsang-an',
      processType: RouteProcessType.twoGroupStaged,
      ownerCoopIds: ['COOP_S_J_GUINSANGAN'],
      destinationCoords: LatLng(10.641947, 121.977399),
    ),
    'ROUTE_LINDERO': RouteProcessInfo(
      routeId: 'ROUTE_LINDERO',
      displayName: 'San Jose - Lindero',
      processType: RouteProcessType.twoGroupStaged,
      ownerCoopIds: ['COOP_S_J_GUINSANGAN'],
      destinationCoords: LatLng(10.612000, 121.973000),
    ),
    'ROUTE_DAO': RouteProcessInfo(
      routeId: 'ROUTE_DAO',
      displayName: 'San Jose - Dao (Tobias Fornier)',
      processType: RouteProcessType.scheduledTwoGroup,
      ownerCoopIds: ['COOP_HD_DAO'],
      destinationCoords: LatLng(10.518000, 122.022000),
    ),
    'ROUTE_ANINIY': RouteProcessInfo(
      routeId: 'ROUTE_ANINIY',
      displayName: 'San Jose - Anini-y',
      processType: RouteProcessType.scheduledSingleGroup,
      ownerCoopIds: ['COOP_FEJODA'],
      destinationCoords: LatLng(10.428000, 122.012000),
    ),
    'ROUTE_SIBALOM': RouteProcessInfo(
      routeId: 'ROUTE_SIBALOM',
      displayName: 'San Jose - Sibalom',
      processType: RouteProcessType.fcfsTimer,
      ownerCoopIds: ['COOP_FEJODA', 'COOP_WVTC'],
      destinationCoords: LatLng(10.786000, 122.016000),
    ),
    'ROUTE_BELISON': RouteProcessInfo(
      routeId: 'ROUTE_BELISON',
      displayName: 'San Jose - Belison',
      processType: RouteProcessType.fcfsPure,
      ownerCoopIds: ['COOP_FEJODA', 'COOP_WVTC'],
      destinationCoords: LatLng(10.840000, 121.960000),
    ),
    'ROUTE_PATNONGON': RouteProcessInfo(
      routeId: 'ROUTE_PATNONGON',
      displayName: 'San Jose - Patnongon',
      processType: RouteProcessType.fcfsPure,
      ownerCoopIds: ['COOP_FEJODA', 'COOP_WVTC'],
      destinationCoords: LatLng(10.913000, 121.996000),
    ),
    'ROUTE_BUGASONG': RouteProcessInfo(
      routeId: 'ROUTE_BUGASONG',
      displayName: 'San Jose - Bugasong',
      processType: RouteProcessType.fcfsPure,
      ownerCoopIds: ['COOP_FEJODA', 'COOP_WVTC'],
      destinationCoords: LatLng(11.043000, 122.062000),
    ),
    'ROUTE_SAN_REMIGIO': RouteProcessInfo(
      routeId: 'ROUTE_SAN_REMIGIO',
      displayName: 'San Jose - San Remigio',
      processType: RouteProcessType.fcfsPure,
      ownerCoopIds: ['COOP_FEJODA'],
      destinationCoords: LatLng(10.785000, 122.085000),
    ),
  };

  static RouteProcessInfo get(String routeId) {
    return routes[routeId] ??
        RouteProcessInfo(
          routeId: routeId,
          displayName: routeId.replaceAll('ROUTE_', '').replaceAll('_', ' '),
          processType: RouteProcessType.fcfsPure,
          ownerCoopIds: [],
          destinationCoords: const LatLng(10.7420, 121.9470),
        );
  }
}