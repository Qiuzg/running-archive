from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session, load_only
from ..database import get_db
from ..models import Route
from ..schemas import RouteSummary, RouteDetail
from ..route_preview import compact_preview

router = APIRouter(prefix="/api/routes", tags=["routes"])


@router.get("", response_model=list[RouteSummary])
def list_routes(
    city: str | None = Query(None),
    search: str | None = Query(None),
    limit: int | None = Query(None, ge=1, le=10000),
    offset: int = Query(0, ge=0),
    preview_points: int | None = Query(None, ge=0, le=1200),
    route_ids: list[str] | None = Query(None),
    db: Session = Depends(get_db),
):
    """List routes. No default limit — returns all records unless limit is explicitly set."""
    if route_ids is not None and len(route_ids) > 20:
        raise HTTPException(status_code=422, detail="At most 20 routes per preview batch")
    if preview_points and preview_points > 300 and not route_ids:
        raise HTTPException(status_code=422, detail="Detailed previews require a batch of route_ids")
    columns = [Route.id, Route.name, Route.city, Route.distance_km, Route.elevation_gain]
    if preview_points != 0:
        columns.append(Route.preview_coordinates)
    if preview_points and preview_points > 300:
        columns.append(Route.coordinates)
    q = db.query(Route).options(load_only(*columns))
    if route_ids is not None:
        q = q.filter(Route.id.in_(route_ids))
    if city:
        q = q.filter(Route.city == city)
    if search:
        q = q.filter(Route.name.contains(search))
    q = q.order_by(Route.id.desc())
    if offset:
        q = q.offset(offset)
    if limit is not None:
        q = q.limit(limit)
    routes = q.all()
    if preview_points is None:
        return routes
    return [RouteSummary(
        id=route.id, name=route.name, city=route.city,
        distance_km=route.distance_km, elevation_gain=route.elevation_gain,
        preview_coordinates=[] if preview_points == 0 else compact_preview(
            (route.coordinates or route.preview_coordinates or []) if preview_points > 300
            else (route.preview_coordinates or []), preview_points),
    ) for route in routes]


@router.get("/{route_id}", response_model=RouteDetail)
def get_route(route_id: str, db: Session = Depends(get_db)):
    route = db.query(Route).filter(Route.id == route_id).first()
    if not route:
        raise HTTPException(status_code=404, detail="Route not found")
    return route
