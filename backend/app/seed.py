"""Representative demo locations; coordinates are approximate, not live listings."""
from sqlalchemy import select
from sqlalchemy.orm import Session

from .database import get_engine
from .models import Retailer, Store

# Leave provider IDs and store numbers null rather than inventing identifiers.
STORES = (
    ("Costco", "Costco King of Prussia", "201 Allendale Rd, King of Prussia, PA 19406", 40.0925, -75.3855),
    ("Trader Joe's", "Trader Joe's Center City", "2121 Market St, Philadelphia, PA 19103", 39.9546, -75.1761),
    ("Walmart", "Walmart South Philadelphia", "1675 S Christopher Columbus Blvd, Philadelphia, PA 19148", 39.9220, -75.1404),
    ("Target", "Target Washington Square", "1128 Chestnut St, Philadelphia, PA 19107", 39.9502, -75.1600),
    ("CVS", "CVS Rittenhouse", "1826 Chestnut St, Philadelphia, PA 19103", 39.9521, -75.1713),
    ("Home Depot", "Home Depot South Philadelphia", "1651 S Christopher Columbus Blvd, Philadelphia, PA 19148", 39.9250, -75.1402),
)


def seed_stores(session: Session) -> None:
    for retailer_name, name, address, latitude, longitude in STORES:
        retailer = session.scalar(select(Retailer).where(Retailer.name == retailer_name))
        if retailer is None:
            retailer = Retailer(name=retailer_name)
            session.add(retailer)
            session.flush()
        existing = session.scalar(select(Store).where(
            Store.retailer_id == retailer.id, Store.name == name, Store.address == address
        ))
        if existing is None:
            session.add(Store(
                retailer_id=retailer.id, name=name, address=address,
                latitude=latitude, longitude=longitude,
            ))
    session.commit()


if __name__ == "__main__":
    with Session(get_engine()) as session:
        seed_stores(session)
    print("Demo stores seeded.")
