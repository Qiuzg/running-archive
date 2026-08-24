from datetime import date, datetime
from typing import Optional
from pydantic import BaseModel


# ---- Route schemas ----
class RouteSummary(BaseModel):
    id: str
    name: str
    city: str = ""
    distance_km: float = 0
    elevation_gain: float = 0
    preview_coordinates: list = []

    model_config = {"from_attributes": True}


class RouteDetail(RouteSummary):
    coordinates: list = []
    elevations: list = []
    time_series: Optional[dict] = None

    model_config = {"from_attributes": True}


# ---- Race schemas ----
class RaceSummary(BaseModel):
    id: str
    name: str
    type: str
    date: date
    city: str = ""
    country: str = ""
    distance_km: float = 0
    finish_time: str = ""
    pace: str = ""
    bib_number: str = ""
    is_pb: bool = False
    route_id: Optional[str] = None
    notes: str = ""
    photos: list = []
    avg_heart_rate: Optional[int] = None
    max_heart_rate: Optional[int] = None
    avg_power: Optional[float] = None

    model_config = {"from_attributes": True}


class RaceDetail(RaceSummary):
    route: Optional[RouteSummary] = None

    model_config = {"from_attributes": True}


# ---- Run schemas ----
class RunSummary(BaseModel):
    id: str
    name: str = ""
    date: date
    city: str | None = ""       # DB may have NULL
    distance_km: float = 0
    duration: str = ""
    pace: str = ""
    route_id: Optional[str] = None
    avg_heart_rate: Optional[int] = None
    avg_power: Optional[float] = None

    model_config = {"from_attributes": True}


# ---- Stats schemas ----
class SummaryStats(BaseModel):
    total_distance_km: float
    yearly_distance_km: float
    marathon_pb: Optional[str] = None
    marathon_pb_name: Optional[str] = None
    half_marathon_pb: Optional[str] = None
    half_marathon_pb_name: Optional[str] = None
    race_count: int
    marathon_count: int


class MonthlyTotal(BaseModel):
    month: int        # 1-12
    distance_km: float


class YearlyStats(BaseModel):
    year: int
    total_distance_km: float
    race_count: int
    marathon_count: int
    half_marathon_count: int
    active_months: int
    monthly_avg_km: float
    longest_run_distance_km: float
    longest_run_name: str = ""
    monthly_totals: list[MonthlyTotal]


class MonthActivity(BaseModel):
    id: str
    name: str = ""
    date: date
    distance_km: float = 0
    pace: str = ""
    route_id: Optional[str] = None
    is_race: bool = False
    race_type: Optional[str] = None

    model_config = {"from_attributes": True}


class MonthDetail(BaseModel):
    year: int
    month: int
    activities: list[MonthActivity]
    total_distance_km: float = 0
    total_count: int = 0


# ---- City boundary ----
class CityBoundaryOut(BaseModel):
    city: str
    geojson: dict

    model_config = {"from_attributes": True}


# ---- Admin schemas ----
class RunCreate(BaseModel):
    id: Optional[str] = None
    name: str = ""
    date: date
    city: str = ""
    distance_km: float
    duration: str = ""
    pace: str = ""
    avg_heart_rate: Optional[int] = None
    max_heart_rate: Optional[int] = None
    source: str = "manual"


class RaceCreate(BaseModel):
    name: str
    type: str  # marathon, half_marathon, 10k, other
    date: date
    city: str = ""
    country: str = ""
    distance_km: float
    finish_time: str = ""
    pace: str = ""
    bib_number: str = ""
    is_pb: bool = False
    route_id: Optional[str] = None
    notes: str = ""
    avg_heart_rate: Optional[int] = None
    avg_power: Optional[float] = None


# ---- Apple Health incremental sync ----
class HealthRoutePoint(BaseModel):
    timestamp: datetime
    latitude: float
    longitude: float
    altitude: float = 0
    speed_mps: Optional[float] = None


class HealthMetricSample(BaseModel):
    elapsed_seconds: float
    value: float


class AppleWorkoutSync(BaseModel):
    id: str
    name: str = "户外跑步"
    start_date: datetime
    distance_km: float
    duration_seconds: float
    city: str = ""
    avg_heart_rate: Optional[int] = None
    max_heart_rate: Optional[int] = None
    avg_cadence: Optional[float] = None
    avg_power: Optional[float] = None
    route_points: list[HealthRoutePoint] = []
    heart_rate_samples: list[HealthMetricSample] = []


class AppleWorkoutSyncRequest(BaseModel):
    workouts: list[AppleWorkoutSync]


class AppleWorkoutSyncResult(BaseModel):
    id: str
    status: str
    route_points: int = 0


class AppleWorkoutSyncResponse(BaseModel):
    synced: list[AppleWorkoutSyncResult]
