from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from ..database import get_db
from ..models import CityBoundary
from ..schemas import CityBoundaryOut

router = APIRouter(prefix="/api/cities", tags=["cities"])


@router.get("", response_model=list[CityBoundaryOut])
def list_cities(db: Session = Depends(get_db)):
    return db.query(CityBoundary).all()


@router.get("/{city}", response_model=CityBoundaryOut)
def get_city_boundary(city: str, db: Session = Depends(get_db)):
    boundary = db.query(CityBoundary).filter(CityBoundary.city == city).first()
    if not boundary:
        from fastapi import HTTPException
        from fastapi.responses import JSONResponse
        raise HTTPException(status_code=404, detail=f"City boundary not found: {city}")
    return boundary
