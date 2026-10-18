"""Errors a service raises when a request can't be met.

Each is an HTTPException carrying the status and detail the API has always
returned, so routes need no translation. Chef's tools tell them apart by type.
"""

from fastapi import HTTPException


class NotFound(HTTPException):
    def __init__(self, detail: str):
        super().__init__(status_code=404, detail=detail)


class Invalid(HTTPException):
    def __init__(self, detail: str):
        super().__init__(status_code=400, detail=detail)


class Conflict(HTTPException):
    def __init__(self, detail: str):
        super().__init__(status_code=409, detail=detail)


class OutOfRange(HTTPException):
    def __init__(self, detail: str):
        super().__init__(status_code=422, detail=detail)


class Unreachable(HTTPException):
    """A page we were asked to fetch could not be fetched."""

    def __init__(self, detail: str):
        super().__init__(status_code=502, detail=detail)


class AlreadyImported(HTTPException):
    def __init__(self, recipe_id: str):
        self.recipe_id = recipe_id
        super().__init__(
            status_code=409,
            detail={
                "message": "That page has already been imported.",
                "recipe_id": recipe_id,
            },
        )


class Conflict(HTTPException):
    def __init__(self, detail: str):
        super().__init__(status_code=409, detail=detail)
