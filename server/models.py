from sqlalchemy import Column, String, Float, Integer, Boolean, JSON, Date, Text, ForeignKey
from sqlalchemy.orm import relationship
from .database import Base


class Route(Base):
    __tablename__ = "routes"

    id = Column(String, primary_key=True, index=True)
    name = Column(String, nullable=False)
    city = Column(String, default="")
    distance_km = Column(Float, default=0)
    elevation_gain = Column(Float, default=0)
    point_count = Column(Integer, default=0)
    privacy = Column(String, default="")
    hidden_start_end_meters = Column(Integer, default=0)
    # preview coordinates: subsampled to ~300 points for thumbnail maps
    preview_coordinates = Column(JSON, default=list)
    # full coordinates: loaded only on detail requests
    coordinates = Column(JSON, default=list)
    elevations = Column(JSON, default=list)
    # time-series data: { elapsed: [], pace: [], elevation: [], heartRate: [] }
    time_series = Column(JSON, default=None)

    # relationships
    race = relationship("Race", back_populates="route", uselist=False)
    run_records = relationship("RunRecord", back_populates="route")


class Race(Base):
    __tablename__ = "races"

    id = Column(String, primary_key=True, index=True)
    source_run_id = Column(String, nullable=True)
    name = Column(String, nullable=False)
    type = Column(String, nullable=False)  # marathon, half_marathon, 10k, other
    date = Column(Date, nullable=False, index=True)
    city = Column(String, default="")
    country = Column(String, default="")
    distance_km = Column(Float, default=0)
    finish_time = Column(String, default="")  # "HH:MM:SS"
    pace = Column(String, default="")          # "MM:SS"
    bib_number = Column(String, default="")
    is_pb = Column(Boolean, default=False)
    route_id = Column(String, ForeignKey("routes.id"), nullable=True)
    notes = Column(Text, default="")
    photos = Column(JSON, default=list)
    avg_heart_rate = Column(Integer, nullable=True)
    max_heart_rate = Column(Integer, nullable=True)
    avg_cadence = Column(Float, nullable=True)
    avg_power = Column(Float, nullable=True)

    route = relationship("Route", back_populates="race")


class RunRecord(Base):
    __tablename__ = "run_records"

    id = Column(String, primary_key=True, index=True)
    name = Column(String, default="")
    date = Column(Date, nullable=False, index=True)
    city = Column(String, default="")
    distance_km = Column(Float, default=0)
    duration = Column(String, default="")       # "HH:MM:SS"
    finish_time = Column(String, default="")    # alias for duration
    pace = Column(String, default="")           # "MM:SS" /km
    route_id = Column(String, ForeignKey("routes.id"), nullable=True)
    avg_heart_rate = Column(Integer, nullable=True)
    max_heart_rate = Column(Integer, nullable=True)
    avg_cadence = Column(Float, nullable=True)
    avg_power = Column(Float, nullable=True)
    source = Column(String, default="apple")    # apple, strava, manual

    route = relationship("Route", back_populates="run_records")


class CityBoundary(Base):
    __tablename__ = "city_boundaries"

    city = Column(String, primary_key=True, index=True)
    geojson = Column(JSON, nullable=False)


class Profile(Base):
    __tablename__ = "profile"

    key = Column(String, primary_key=True)
    value = Column(String, default="")
