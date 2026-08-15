from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session, load_only
from ..database import get_db
from ..models import Route
from ..schemas import RouteSummary, RouteDetail

router = APIRouter(prefix="/api/routes", tags=["routes"])


@router.get("", response_model=list[RouteSummary])
def list_routes(
    city: str | None = Query(None),
    search: str | None = Query(None),
    limit: int | None = Query(None, ge=1, le=10000),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db),
):
    """List routes. No default limit — returns all records unless limit is explicitly set."""
    q = db.query(Route).options(
        load_only(
            Route.id,
            Route.name,
            Route.city,
            Route.distance_km,
            Route.elevation_gain,
            Route.preview_coordinates,
        )
    )
    if city:
        q = q.filter(Route.city == city)
    if search:
        q = q.filter(Route.name.contains(search))
    q = q.order_by(Route.id.desc())
    if offset:
        q = q.offset(offset)
    if limit is not None:
        q = q.limit(limit)
    return q.all()


@router.get("/{route_id}", response_model=RouteDetail)
def get_route(route_id: str, db: Session = Depends(get_db)):
    route = db.query(Route).filter(Route.id == route_id).first()
    if not route:
        raise HTTPException(status_code=404, detail="Route not found")
    return route
