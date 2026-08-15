from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from ..database import get_db
from ..models import RunRecord, Race
from ..schemas import RunCreate, RaceCreate, RunSummary, RaceSummary

router = APIRouter(prefix="/api/admin", tags=["admin"])


# ---- Runs CRUD ----
@router.post("/runs", response_model=RunSummary, status_code=201)
def create_run(data: RunCreate, db: Session = Depends(get_db)):
    import uuid
    run_id = data.id or f"manual-{uuid.uuid4().hex[:12]}"
    run = RunRecord(
        id=run_id,
        name=data.name,
        date=data.date,
        city=data.city,
        distance_km=data.distance_km,
        duration=data.duration,
        finish_time=data.duration,
        pace=data.pace,
        avg_heart_rate=data.avg_heart_rate,
        max_heart_rate=data.max_heart_rate,
        source=data.source,
    )
    db.add(run)
    db.commit()
    db.refresh(run)
    return run


@router.put("/runs/{run_id}", response_model=RunSummary)
def update_run(run_id: str, data: RunCreate, db: Session = Depends(get_db)):
    run = db.query(RunRecord).filter(RunRecord.id == run_id).first()
    if not run:
        raise HTTPException(status_code=404, detail="Run not found")
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(run, field, value)
    if data.duration:
        run.finish_time = data.duration
    db.commit()
    db.refresh(run)
    return run


@router.delete("/runs/{run_id}", status_code=204)
def delete_run(run_id: str, db: Session = Depends(get_db)):
    run = db.query(RunRecord).filter(RunRecord.id == run_id).first()
    if not run:
        raise HTTPException(status_code=404, detail="Run not found")
    db.delete(run)
    db.commit()


# ---- Races CRUD ----
@router.post("/races", response_model=RaceSummary, status_code=201)
def create_race(data: RaceCreate, db: Session = Depends(get_db)):
    import uuid
    race_id = f"manual-{uuid.uuid4().hex[:12]}"
    race = Race(
        id=race_id,
        name=data.name,
        type=data.type,
        date=data.date,
        city=data.city,
        country=data.country,
        distance_km=data.distance_km,
        finish_time=data.finish_time,
        pace=data.pace,
        bib_number=data.bib_number,
        is_pb=data.is_pb,
        route_id=data.route_id,
        notes=data.notes,
        avg_heart_rate=data.avg_heart_rate,
        avg_power=data.avg_power,
    )
    db.add(race)
    db.commit()
    db.refresh(race)
    return race


@router.put("/races/{race_id}", response_model=RaceSummary)
def update_race(race_id: str, data: RaceCreate, db: Session = Depends(get_db)):
    race = db.query(Race).filter(Race.id == race_id).first()
    if not race:
        raise HTTPException(status_code=404, detail="Race not found")
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(race, field, value)
    db.commit()
    db.refresh(race)
    return race


@router.delete("/races/{race_id}", status_code=204)
def delete_race(race_id: str, db: Session = Depends(get_db)):
    race = db.query(Race).filter(Race.id == race_id).first()
    if not race:
        raise HTTPException(status_code=404, detail="Race not found")
    db.delete(race)
    db.commit()
