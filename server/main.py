from pathlib import Path
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .database import engine, Base
from .routers import routes, races, runs, stats, cities, admin, config

# Create tables on startup if they don't exist
Base.metadata.create_all(bind=engine)

app = FastAPI(
    title="Running Archive API",
    description="Personal running log — races, training runs, routes, and yearly statistics",
    version="2.0.0",
)

# CORS — allow the dev server and the production domain
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Restrict in production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# API routers
app.include_router(routes.router)
app.include_router(races.router)
app.include_router(runs.router)
app.include_router(stats.router)
app.include_router(cities.router)
app.include_router(admin.router)
app.include_router(config.router)


@app.get("/api/health")
def health():
    return {"status": "ok", "version": "2.0.0"}


# In production, Nginx serves static files. In dev, FastAPI can serve them.
STATIC_DIR = Path(__file__).resolve().parent.parent
if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server.main:app", host="0.0.0.0", port=8000, reload=True)
