"""Serve map configuration from the server so keys don't leak into bundles."""
import os

from fastapi import APIRouter

router = APIRouter(prefix="/api/config", tags=["config"])

AMAP_KEY = "d27e9d7cea2761b3c3d1fa55b0a077dc"
AMAP_SECURITY = "18e22c62bd9cee938b85f1ee6f37b794"
CARTO_KEY = os.getenv("CARTO_API_KEY", "").strip()


@router.get("/amap")
def get_amap_config():
    """Returns AMap config — keys stay server-side, not baked into JS bundle."""
    return {
        "key": AMAP_KEY,
        "securityJsCode": AMAP_SECURITY,
        "styles": {
            "light": "amap://styles/whitesmoke",
            "dark": "amap://styles/dark",
        },
    }


@router.get("/carto")
def get_carto_config():
    """Returns the optional public CARTO basemap key configured on the server."""
    return {"key": CARTO_KEY}
