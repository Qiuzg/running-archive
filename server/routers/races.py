from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session, joinedload
from ..database import get_db
from ..models import Race
from ..schemas import RaceSummary, RaceDetail

router = APIRouter(prefix="/api/races", tags=["races"])


@router.get("", response_model=list[RaceSummary])
def list_races(
    type: str | None = Query(None, description="marathon, half_marathon, 10k, other"),
    year: int | None = Query(None),
    db: Session = Depends(get_db),
):
    q = db.query(Race)
    if type:
        q = q.filter(Race.type == type)
    if year:
        q = q.filter(Race.date >= f"{year}-01-01", Race.date <= f"{year}-12-31")
    q = q.order_by(Race.date.desc())
    return q.all()


@router.get("/{race_id}", response_model=RaceDetail)
def get_race(race_id: str, db: Session = Depends(get_db)):
    race = db.query(Race).options(joinedload(Race.route)).filter(Race.id == race_id).first()
    if not race:
        raise HTTPException(status_code=404, detail="Race not found")
    return race
