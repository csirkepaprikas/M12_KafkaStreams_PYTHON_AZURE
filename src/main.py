import datetime
from dateutil.parser import parse as parse_date
import faust
import logging


class ExpediaRecord(faust.Record):
    id: float
    date_time: str
    site_name: int
    posa_container: int
    user_location_country: int
    user_location_region: int
    user_location_city: int
    orig_destination_distance: float
    user_id: int
    is_mobile: int
    is_package: int
    channel: int
    srch_ci: str
    srch_co: str
    srch_adults_cnt: int
    srch_children_cnt: int
    srch_rm_cnt: int
    srch_destination_id: int
    srch_destination_type_id: int
    hotel_id: int


class ExpediaExtRecord(ExpediaRecord):
    stay_category: str


logger = logging.getLogger(__name__)
app = faust.App('kafkastreams', broker='kafka://kafka:9092')
source_topic = app.topic('expedia', value_type=ExpediaRecord)
destination_topic = app.topic('expedia_ext', value_type=ExpediaExtRecord)


@app.agent(source_topic, sink=[destination_topic])
async def handle(messages):
    async for message in messages:
        if message is None:
            logger.info('No messages')
            continue

        data = {
            'id': message.id,
            'date_time': message.date_time,
            'site_name': message.site_name,
            'posa_container': message.posa_container,
            'user_location_country': message.user_location_country,
            'user_location_region': message.user_location_region,
            'user_location_city': message.user_location_city,
            'orig_destination_distance': message.orig_destination_distance,
            'user_id': message.user_id,
            'is_mobile': message.is_mobile,
            'is_package': message.is_package,
            'channel': message.channel,
            'srch_ci': message.srch_ci,
            'srch_co': message.srch_co,
            'srch_adults_cnt': message.srch_adults_cnt,
            'srch_children_cnt': message.srch_children_cnt,
            'srch_rm_cnt': message.srch_rm_cnt,
            'srch_destination_id': message.srch_destination_id,
            'srch_destination_type_id': message.srch_destination_type_id,
            'hotel_id': message.hotel_id
        }

        # Set default value for stay category
        stay_category = 'Erroneous data'

        try:
            # Parse check-in and check-out dates. All incorrect values is filtering
            # on this stage
            check_in = parse_date(message.srch_ci)
            check_out = parse_date(message.srch_co)

        except:
            yield ExpediaExtRecord(**data, stay_category=stay_category)

        # Calculate the duration in days
        duration = (check_out - check_in).days

        # Determine stay category for correct dates
        if 1 <= duration <=4:
            stay_category = 'Short stay'
        elif 5 <= duration <= 10:
            stay_category = 'Standard stay'
        elif 11 <= duration <= 14:
            stay_category = 'Standard extended stay'
        elif duration > 14:
            stay_category = 'Long stay'

        yield ExpediaExtRecord(**data, stay_category=stay_category)


if __name__ == '__main__':
    app.main()
