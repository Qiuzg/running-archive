from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from ..database import get_db
from ..models import RunRecord
from ..schemas import RunSummary

router = APIRouter(prefix="/api/runs", tags=["runs"])


@router.get("", response_model=list[RunSummary])
def list_runs(
    year: int | None = Query(None),
    month: int | None = Query(None, ge=1, le=12),
    limit: int | None = Query(None, ge=1, le=10000),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db),
):
    """List runs. No default limit — returns all records unless limit is explicitly set."""
    q = db.query(RunRecord)
    if year:
        q = q.filter(RunRecord.date >= f"{year}-01-01", RunRecord.date <= f"{year}-12-31")
    if month and year:
        q = q.filter(
            RunRecord.date >= f"{year}-{month:02d}-01",
            RunRecord.date <= f"{year}-{month:02d}-31",
        )
    q = q.order_by(RunRecord.date.desc())
    if offset:
        q = q.offset(offset)
    if limit is not None:
        q = q.limit(limit)
    return q.all()


@router.get("/{run_id}", response_model=RunSummary)
def get_run(run_id: str, db: Session = Depends(get_db)):
    run = db.query(RunRecord).filter(RunRecord.id == run_id).first()
    if not run:
        raise HTTPException(status_code=404, detail="Run not found")
    return run
