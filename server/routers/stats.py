from datetime import date
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from sqlalchemy import func
from ..database import get_db
from ..models import Race, RunRecord
from ..schemas import (
    SummaryStats,
    YearlyStats,
    MonthlyTotal,
    MonthDetail,
    MonthActivity,
)

router = APIRouter(prefix="/api/stats", tags=["stats"])


def _parse_time_to_seconds(value: str) -> float:
    """Convert 'HH:MM:SS' or 'MM:SS' to total seconds."""
    if not value:
        return float("inf")
    parts = value.split(":")
    if len(parts) == 3:
        return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    elif len(parts) == 2:
        return int(parts[0]) * 60 + int(parts[1])
    return float("inf")


@router.get("/summary", response_model=SummaryStats)
def get_summary(year: int | None = Query(None), db: Session = Depends(get_db)):
    """Get overall summary stats: total km, PBs, year distance, race counts."""
    current_year = year or date.today().year

    # Total distance
    total_runs_km = db.query(func.coalesce(func.sum(RunRecord.distance_km), 0)).scalar()
    total_races_km = db.query(func.coalesce(func.sum(Race.distance_km), 0)).scalar()
    total_km = round(total_runs_km + total_races_km, 1)

    # Yearly distance
    year_runs_km = db.query(func.coalesce(func.sum(RunRecord.distance_km), 0)).filter(
        RunRecord.date >= f"{current_year}-01-01", RunRecord.date <= f"{current_year}-12-31"
    ).scalar()
    year_races_km = db.query(func.coalesce(func.sum(Race.distance_km), 0)).filter(
        Race.date >= f"{current_year}-01-01", Race.date <= f"{current_year}-12-31"
    ).scalar()
    yearly_km = round(year_runs_km + year_races_km, 1)

    # Marathon PB
    marathons = db.query(Race).filter(Race.type == "marathon").all()
    marathon_pb = min(marathons, key=lambda r: _parse_time_to_seconds(r.finish_time)) if marathons else None

    # Half marathon PB
    halfs = db.query(Race).filter(Race.type == "half_marathon").all()
    half_pb = min(halfs, key=lambda r: _parse_time_to_seconds(r.finish_time)) if halfs else None

    # Counts
    race_count = db.query(func.count(Race.id)).scalar()
    marathon_count = db.query(func.count(Race.id)).filter(Race.type == "marathon").scalar()

    return SummaryStats(
        total_distance_km=total_km,
        yearly_distance_km=yearly_km,
        marathon_pb=marathon_pb.finish_time if marathon_pb else None,
        marathon_pb_name=marathon_pb.name if marathon_pb else None,
        half_marathon_pb=half_pb.finish_time if half_pb else None,
        half_marathon_pb_name=half_pb.name if half_pb else None,
        race_count=race_count,
        marathon_count=marathon_count,
    )


@router.get("/yearly/{year}", response_model=YearlyStats)
def get_yearly_stats(year: int, db: Session = Depends(get_db)):
    """Get yearly statistics with monthly breakdown."""
    # Monthly totals from both runs and races
    monthly_totals = []
    for m in range(1, 13):
        runs_km = db.query(func.coalesce(func.sum(RunRecord.distance_km), 0)).filter(
            RunRecord.date >= f"{year}-{m:02d}-01",
            RunRecord.date <= f"{year}-{m:02d}-31",
        ).scalar()
        races_km = db.query(func.coalesce(func.sum(Race.distance_km), 0)).filter(
            Race.date >= f"{year}-{m:02d}-01",
            Race.date <= f"{year}-{m:02d}-31",
        ).scalar()
        total = round(runs_km + races_km, 1)
        if total > 0 or any(t.distance_km > 0 for t in monthly_totals):
            monthly_totals.append(MonthlyTotal(month=m, distance_km=total))

    year_dist = round(sum(t.distance_km for t in monthly_totals), 1)

    # Year races
    year_races = db.query(Race).filter(
        Race.date >= f"{year}-01-01", Race.date <= f"{year}-12-31"
    ).all()
    marathon_count = sum(1 for r in year_races if r.type == "marathon")
    half_count = sum(1 for r in year_races if r.type == "half_marathon")

    # Longest run
    longest_run = db.query(RunRecord).filter(
        RunRecord.date >= f"{year}-01-01", RunRecord.date <= f"{year}-12-31"
    ).order_by(RunRecord.distance_km.desc()).first()
    longest_race = db.query(Race).filter(
        Race.date >= f"{year}-01-01", Race.date <= f"{year}-12-31"
    ).order_by(Race.distance_km.desc()).first()

    if longest_run and longest_race:
        longest = longest_run if (longest_run.distance_km or 0) >= (longest_race.distance_km or 0) else longest_race
        longest_dist = longest.distance_km or 0
        longest_name = getattr(longest, "name", "")
    elif longest_run:
        longest_dist = longest_run.distance_km or 0
        longest_name = longest_run.name
    elif longest_race:
        longest_dist = longest_race.distance_km or 0
        longest_name = longest_race.name
    else:
        longest_dist = 0
        longest_name = ""

    # Active months
    active_months = sum(1 for t in monthly_totals if t.distance_km > 0)
    monthly_avg = round(year_dist / active_months, 1) if active_months > 0 else 0

    return YearlyStats(
        year=year,
        total_distance_km=year_dist,
        race_count=len(year_races),
        marathon_count=marathon_count,
        half_marathon_count=half_count,
        active_months=active_months,
        monthly_avg_km=monthly_avg,
        longest_run_distance_km=longest_dist,
        longest_run_name=longest_name,
        monthly_totals=monthly_totals,
    )


@router.get("/monthly/{year}/{month}", response_model=MonthDetail)
def get_month_detail(year: int, month: int, db: Session = Depends(get_db)):
    """Get daily activities for a specific month."""
    activities = []

    runs = db.query(RunRecord).filter(
        RunRecord.date >= f"{year}-{month:02d}-01",
        RunRecord.date <= f"{year}-{month:02d}-31",
    ).order_by(RunRecord.date.asc()).all()

    races = db.query(Race).filter(
        Race.date >= f"{year}-{month:02d}-01",
        Race.date <= f"{year}-{month:02d}-31",
    ).order_by(Race.date.asc()).all()

    for r in runs:
        activities.append(MonthActivity(
            id=r.id, name=r.name, date=r.date,
            distance_km=r.distance_km or 0, pace=r.pace or "",
            route_id=r.route_id, is_race=False, race_type=None,
        ))

    for r in races:
        activities.append(MonthActivity(
            id=r.id, name=r.name, date=r.date,
            distance_km=r.distance_km or 0, pace=r.pace or "",
            route_id=r.route_id, is_race=True, race_type=r.type,
        ))

    activities.sort(key=lambda a: a.date if a.date else date.min)
    total_km = round(sum(a.distance_km for a in activities), 1)

    return MonthDetail(
        year=year, month=month,
        activities=activities,
        total_distance_km=total_km,
        total_count=len(activities),
    )


@router.get("/years", response_model=list[int])
def list_years(db: Session = Depends(get_db)):
    """Get all available years from both runs and races."""
    run_years = {r[0] for r in db.query(func.substr(RunRecord.date, 1, 4)).distinct().all() if r[0]}
    race_years = {r[0] for r in db.query(func.substr(Race.date, 1, 4)).distinct().all() if r[0]}
    all_years = run_years | race_years
    return sorted([int(y) for y in all_years], reverse=True)
