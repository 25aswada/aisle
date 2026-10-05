import base64
import binascii
import re
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class RetailerResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str
    domain: str | None = None


class StoreResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    retailer_id: int
    name: str
    address: str
    latitude: float
    longitude: float
    external_place_id: str | None
    store_number: str | None
    retailer: RetailerResponse
    # Flat copy of retailer.name; the iOS client reads this field.
    retailer_name: str
    # logo.dev image for the retailer, or null without a domain or key.
    retailer_logo_url: str | None = None


class NearbyStoreResponse(StoreResponse):
    distance_miles: float


class NearbyResponse(BaseModel):
    stores: list[NearbyStoreResponse]
    message: str | None = None


Confidence = Literal["high", "medium", "low"]
Availability = Literal["likely", "unlikely", "unknown"]
LocationSource = Literal["database", "observations", "store_layout", "model", "fallback"]


class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=200)
    store_id: int | None = None

    @field_validator("query")
    @classmethod
    def query_not_blank(cls, value: str) -> str:
        value = " ".join(value.split())
        if not value:
            raise ValueError("query must not be blank")
        return value


# A photo is base64 JPEG or PNG; the app downsizes to about 1024 px, well under this.
MAX_PHOTO_BASE64 = 4_000_000


def check_photo(value: str | None) -> str | None:
    """Base64 for a JPEG or PNG, or a ValueError."""
    if value is None:
        return None
    try:
        data = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("image must be base64") from None
    if not (data.startswith(b"\xff\xd8") or data.startswith(b"\x89PNG")):
        raise ValueError("image must be a JPEG or PNG")
    return value


class ChatMessageIn(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(default="", max_length=4000)
    # A photo the shopper sent with this message.
    image: str | None = Field(default=None, max_length=MAX_PHOTO_BASE64)

    @field_validator("image")
    @classmethod
    def image_is_a_photo(cls, value: str | None) -> str | None:
        return check_photo(value)


class ChatRequest(BaseModel):
    """A follow-up: the whole conversation so far, ending with the shopper's new message."""
    store_id: int
    messages: list[ChatMessageIn] = Field(min_length=1, max_length=40)

    @field_validator("messages")
    @classmethod
    def ends_with_shopper(cls, value: list[ChatMessageIn]) -> list[ChatMessageIn]:
        last = value[-1]
        if last.role != "user" or not (last.content.strip() or last.image):
            raise ValueError("the last message must be the shopper's")
        if any(m.image and m.role != "user" for m in value):
            raise ValueError("only the shopper's messages can have photos")
        if any(not (m.content.strip() or m.image) for m in value):
            raise ValueError("messages need text or a photo")
        return value


class IdentifyRequest(BaseModel):
    """A photo of something the shopper wants to find, and anything they typed with it."""
    store_id: int | None = None
    image: str = Field(max_length=MAX_PHOTO_BASE64)
    note: str | None = Field(default=None, max_length=200)

    @field_validator("image")
    @classmethod
    def image_is_a_photo(cls, value: str) -> str:
        return check_photo(value)


class IdentifyResponse(BaseModel):
    # A short search phrase for the item, or null when there's no product to name.
    item: str | None


class ChatResponse(BaseModel):
    # Null when no AI provider is configured or it couldn't answer.
    reply: str | None
    # When the follow-up asks where to find a new item: that item's search, as from
    # POST /search (its `explanation` is null; `reply` is the answer to show).
    search: "SearchResponse | None" = None


class CategoryOut(BaseModel):
    slug: str
    name: str


class ConceptOut(BaseModel):
    id: int
    name: str


class LocationOut(BaseModel):
    department: str | None
    zone_id: int | None = None
    # Exact aisle/section text appears only when a database row supports it.
    aisle: str | None = None
    section: str | None = None
    neighbors: list[str] = []


class ReportCountsOut(BaseModel):
    found: int
    not_here: int


class SearchResponse(BaseModel):
    search_id: str | None = None
    query: str
    item: str
    modifiers: list[str]
    quantity: str | None
    store_id: int | None
    concept: ConceptOut | None
    category: CategoryOut | None
    location: LocationOut
    availability: Availability
    confidence: Confidence
    source: LocationSource
    # Shopper reports for the suggested zone at this store; null without a store or zone.
    reports: ReportCountsOut | None = None
    # AI-written "where to find it" text, checked against the facts above; null without a
    # model or when the text didn't pass checks (the app then writes its own).
    explanation: str | None = None


AISLE_LABEL = re.compile(r"[A-Za-z0-9 #&'./-]{1,24}")


class FeedbackRequest(BaseModel):
    store_id: int
    item: str = Field(min_length=1, max_length=200)
    verdict: Literal["found", "not_here"]
    search_id: str | None = Field(default=None, max_length=36)
    # Where the shopper found it (correction) or where it wasn't (not_here).
    zone_id: int | None = None
    aisle: str | None = Field(default=None, max_length=40)
    note: str | None = Field(default=None, max_length=280)

    @field_validator("item")
    @classmethod
    def item_not_blank(cls, value: str) -> str:
        value = " ".join(value.split())
        if not value:
            raise ValueError("item must not be blank")
        return value

    @field_validator("aisle", "note")
    @classmethod
    def blank_to_none(cls, value: str | None) -> str | None:
        value = " ".join((value or "").split())
        return value or None

    @field_validator("aisle")
    @classmethod
    def aisle_like(cls, value: str | None) -> str | None:
        """Aisle text is shown to other shoppers (and given to the AI) once reports agree,
        so only a short aisle or sign label is kept ("Aisle 7", "12B", "Frozen 4")."""
        return value if value and AISLE_LABEL.fullmatch(value) else None


class FeedbackResponse(BaseModel):
    id: int
    store_id: int
    verdict: Literal["found", "not_here"]
    zone_id: int | None
    concept_id: int | None
    reports: ReportCountsOut | None


class LayoutPoint(BaseModel):
    x: float
    y: float


class LayoutZoneOut(BaseModel):
    id: int
    name: str
    # Approximate floor-plan position (x 0..1 left to right, y 0..1 front to back).
    x: float | None
    y: float | None
    source: str


class StoreLayoutOut(BaseModel):
    store_id: int
    entrance: LayoutPoint | None
    checkout: LayoutPoint | None
    zones: list[LayoutZoneOut]
    # True when any position comes from the store format's template, not this store.
    approximate: bool


class StoreZoneOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    name: str
    aisle_label: str | None
    source: str


class ListParseRequest(BaseModel):
    text: str = Field(max_length=2000)


class ListScanRequest(BaseModel):
    """A photo of a shopping list to read and split into items."""
    image: str = Field(max_length=MAX_PHOTO_BASE64)

    @field_validator("image")
    @classmethod
    def image_is_a_photo(cls, value: str) -> str:
        return check_photo(value)


class ParsedListItem(BaseModel):
    text: str
    quantity: str | None
    category: CategoryOut | None


class ListParseResponse(BaseModel):
    items: list[ParsedListItem]


class RouteItemIn(BaseModel):
    id: str = Field(min_length=1, max_length=64)
    text: str = Field(min_length=1, max_length=200)


class RouteRequest(BaseModel):
    store_id: int
    items: list[RouteItemIn] = Field(min_length=1, max_length=100)


class RouteStopItem(BaseModel):
    id: str
    text: str
    aisle: str | None
    section: str | None
    neighbors: list[str]
    confidence: Confidence
    source: LocationSource


class RouteStop(BaseModel):
    order: int
    zone_id: int | None
    department: str
    # Approximate floor-plan position (0..1); null when the zone has none.
    x: float | None
    y: float | None
    items: list[RouteStopItem]


class UnplacedItem(BaseModel):
    id: str
    text: str
    reason: Literal["unknown", "not_carried"]


class RouteResponse(BaseModel):
    store_id: int
    stops: list[RouteStop]
    unplaced: list[UnplacedItem]
    # Rough walking distance in floor-plan units, for comparing orders.
    distance: float


class MultiRouteRequest(BaseModel):
    # Stores in the order the shopper wants to visit them.
    store_ids: list[int] = Field(min_length=2, max_length=4)
    items: list[RouteItemIn] = Field(min_length=1, max_length=100)


class RouteLeg(BaseModel):
    store_id: int
    store_name: str
    retailer_name: str
    stops: list[RouteStop]
    unplaced: list[UnplacedItem]
    distance: float


class MultiRouteResponse(BaseModel):
    legs: list[RouteLeg]
    # Items none of the stores is likely to carry.
    unplaced: list[UnplacedItem]


# Event names the app may send. Anything else is rejected so analytics stay a known set.
ANALYTICS_EVENT_NAMES = (
    "app_opened", "store_selected", "search_submitted", "search_failed", "recent_search_tapped",
    "feedback_sent", "list_items_added", "shopping_started", "shopping_item_found",
    "shopping_item_skipped", "shopping_finished", "follow_up_sent",
)
AnalyticsValue = str | int | float | bool | None


class AnalyticsEventIn(BaseModel):
    name: Literal[ANALYTICS_EVENT_NAMES]  # type: ignore[valid-type]
    occurred_at: datetime | None = None
    properties: dict[str, AnalyticsValue] = Field(default_factory=dict, max_length=12)

    @field_validator("properties")
    @classmethod
    def small_values(cls, value: dict) -> dict:
        for key, item in value.items():
            if len(key) > 40:
                raise ValueError("property names are at most 40 characters")
            if isinstance(item, str) and len(item) > 80:
                raise ValueError("string properties are at most 80 characters")
        return value


class AnalyticsBatch(BaseModel):
    events: list[AnalyticsEventIn] = Field(min_length=1, max_length=50)


class AnalyticsAccepted(BaseModel):
    accepted: int


ChatResponse.model_rebuild()


# --- Accounts ---

class PhoneStart(BaseModel):
    phone: str = Field(min_length=7, max_length=32)


class PhoneVerify(PhoneStart):
    code: str = Field(pattern=r"^\d{4,10}$")


class EmailStart(BaseModel):
    email: str = Field(min_length=3, max_length=320)


class EmailVerify(EmailStart):
    code: str = Field(pattern=r"^\d{6}$")


class AppleSignIn(BaseModel):
    identity_token: str = Field(min_length=20, max_length=8000)
    # The raw nonce the app hashed into Apple's request; a token can't be replayed without it.
    nonce: str = Field(min_length=8, max_length=200)
    # Apple's one-time code, traded for the refresh token revoked when the account is deleted.
    authorization_code: str | None = Field(default=None, max_length=2000)
    # Apple shares the name only on the very first sign-in, and only with the app.
    first_name: str | None = Field(default=None, max_length=40)


class GoogleSignIn(BaseModel):
    id_token: str = Field(min_length=20, max_length=8000)
    nonce: str = Field(min_length=8, max_length=200)


class AccountDeletion(BaseModel):
    # A fresh Sign in with Apple code from the app, traded for a token to revoke. Accounts
    # without Apple, and older apps, send no body.
    authorization_code: str | None = Field(default=None, max_length=2000)


class AppleNotification(BaseModel):
    # Sign in with Apple's server-to-server notification: a JWT Apple signed.
    payload: str = Field(min_length=20, max_length=8000)


class CodeSent(BaseModel):
    # Where the code went, masked a little for display ("+1 •••• 0123").
    sent_to: str
    # Seconds before another code can be sent to the same place.
    retry_after: int


class UserOut(BaseModel):
    id: int
    # The app passes this to StoreKit as appAccountToken when buying Aisle+.
    plus_token: str
    first_name: str
    email: str | None
    phone: str | None
    wants_tips: bool
    # How this account can sign in: apple, google, phone, email.
    providers: list[str]


class AuthOut(BaseModel):
    # Send as "Authorization: Bearer <token>". It ends after 90 days unused, or on sign out.
    token: str
    user: UserOut
    # True when this sign-in created the account, so the app asks for a name.
    is_new: bool


class ProfileUpdate(BaseModel):
    first_name: str | None = Field(default=None, max_length=40)
    wants_tips: bool | None = None

    @field_validator("first_name")
    @classmethod
    def name_not_blank(cls, value: str | None) -> str | None:
        if value is not None and not value.strip():
            raise ValueError("first_name must not be blank")
        return value.strip() if value else value


# --- Aisle+ ---

class AppStoreNotification(BaseModel):
    """App Store Server Notifications V2: one signed JWS."""
    signedPayload: str = Field(min_length=20, max_length=60000)


class PlusSync(BaseModel):
    # StoreKit 2 `jwsRepresentation` of each current Aisle+ entitlement.
    transactions: list[str] = Field(default_factory=list, max_length=20)
    # "Restore purchases": also take over subscriptions bought for an account that has
    # since been deleted (still billed by Apple), not just ones bought for this account.
    claim: bool = False


class UsageOut(BaseModel):
    used: int
    limit: int


class PlusStatus(BaseModel):
    is_plus: bool
    expires_at: datetime | None = None
    product_id: str | None = None
    # Today's use of the free tier's limited features (not counted for Aisle+).
    search: UsageOut
    photo_search: UsageOut
    follow_up: UsageOut
    # Searches answered with the AI's help; past the limit, searches use Aisle's own answers.
    ai_search: UsageOut


# --- Shared lists ---

class SharedItemIn(BaseModel):
    # The phone's own id for the item (a UUID string), kept on every device.
    id: str = Field(min_length=1, max_length=36)
    text: str = Field(min_length=1, max_length=200)
    quantity: str | None = Field(default=None, max_length=40)
    category_name: str | None = Field(default=None, max_length=80)
    is_done: bool = False
    position: float = 0


class SharedItemOut(SharedItemIn):
    pass


class SharedListCreate(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    items: list[SharedItemIn] = Field(default_factory=list, max_length=500)


class SharedListRename(BaseModel):
    name: str = Field(min_length=1, max_length=60)


class SharedListChange(BaseModel):
    op: Literal["upsert", "delete"]
    item: SharedItemIn | None = None
    id: str | None = Field(default=None, max_length=36)


class SharedListChanges(BaseModel):
    # The app sends at most 100 at a time (bigger edits go in several requests).
    changes: list[SharedListChange] = Field(max_length=100)


class JoinSharedList(BaseModel):
    code: str = Field(min_length=4, max_length=20)


class SharedMemberOut(BaseModel):
    # The membership's id, for the owner to remove someone.
    id: int
    first_name: str
    is_owner: bool
    is_you: bool


class SharedListOut(BaseModel):
    id: str
    name: str
    # Only the owner gets the code: they decide who's invited.
    invite_code: str | None = None
    version: int
    is_owner: bool
    members: list[SharedMemberOut]
    items: list[SharedItemOut]


class SharedListSummary(BaseModel):
    id: str
    name: str
    version: int
    is_owner: bool
    item_count: int
    members: list[SharedMemberOut]


class SharedListReport(BaseModel):
    reason: Literal["spam", "harassment", "inappropriate", "other"]
    note: str | None = Field(default=None, max_length=500)
    # Also leave the list (not for its owner, who can delete it instead).
    leave: bool = False
