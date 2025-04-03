#!/usr/bin/env python3
import datetime
import json
import sys

import urllib3

API_URL = 'https://auth.qendercore.com:8000/v1'
TOKEN_CACHE = '/tmp/qendercore-token.json'


def get_token(http, login, password):
    req_auth = http.request(
        'POST',
        '%s/auth/login' % API_URL,
        encode_multipart=False,
        fields={
            "username": login,
            "password": password
        },
    )

    resp_auth = json.loads(req_auth.data.decode('utf-8'))
    print(resp_auth)

    token = resp_auth['access_token']
    return token


def get_cached_token(http, login, password):
    token = None
    try:
        with open(TOKEN_CACHE) as f:
            data = json.loads(f.read())
            token = data['token']
            isValid = validate_token(http, token)
            if isValid:
                return token
            raise Exception("Invalid token")
    except Exception as e:
        print("Failed to read token")
        print(e)
        token = get_token(http, login, password)
        with open(TOKEN_CACHE, "w") as f:
            f.write(json.dumps({'token': token}))
    return token


def validate_token(http, token):
    try:
        req_account = http.request(
            'GET',
            '%s/s/accountinfo' % API_URL,
            headers={
                'Authorization': 'Bearer ' + token,
            }
        )
        resp_account = json.loads(req_account.data.decode('utf-8'))
        with open('resp_account.json', "w") as f:
            f.write(json.dumps(resp_account, indent=2))

        if "uid" in resp_account:
            return True
        else:
            print("Unexpected validation response: %s" % str(resp_account))
            return False
    except Exception as e:
        print("Failed to validate token")
        print(e)
        return False


def flatten(xss):
    return [x for xs in xss for x in xs]


def extract_requests(layout):
    rows = list(flatten(map(lambda r: r["cells"], layout["rows"])))
    devparams = [w["widget"] for w in rows]

    def mapParam(p):
        out = {
            'datafetch': {"fetchType": p["datafetch"]["fetchType"],
                          "deviceId": p["datafetch"]["parameters"]['deviceId']} | (
                             p["datafetch"]['parameters']),
        }
        if 'echartOpts' in p:
            out['echartOpts'] = p['echartOpts']
        return out

    idtoparams = list(
        map(mapParam, devparams))
    titles = [w["title"] for w in devparams]
    types = [w["widgetType"] for w in devparams]

    alldefs = zip(idtoparams, titles, types)
    return alldefs


def fetch_qc_data(login, password):
    headers = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64; rv:124.0) Gecko/20100101 Firefox/124.0',
               'Origin': 'https://www.qendercore.com',
               'Referer': 'https://www.qendercore.com',
               'Accept': 'application/json',
               "Accept-Encoding": "gzip, deflate, br",
               "Accept-Language": "en-US,en;q=0.5",
               "Cache-Control": "no-cache",
               "Pragma": "no-cache",
               "Connection": "keep-alive",
               "Sec-Fetch-Dest": "empty",
               "Sec-Fetch-Mode": "cors",
               "Sec-Fetch-Site": "same-site",
               "Sec-GPC": 1,
               "x-qc-client-seq": "W.1.1",
               }
    http = urllib3.PoolManager(1, headers=headers)

    token = get_cached_token(http, login, password)

    ##
    req_dashboard = http.request(
        'GET',
        '%s/s/dashboard' % API_URL,
        headers={
            'Authorization': 'Bearer ' + token,
        }
    )
    resp_dashboard = json.loads(req_dashboard.data.decode('utf-8'))
    with open('resp_dashboard.json', "w") as f:
        f.write(json.dumps(resp_dashboard, indent=2))
    filtered = filter(lambda p: p[0]['echartOpts']['qcMode'] != "history", extract_requests(resp_dashboard))

    result = {'solar_generation': 0, 'consumption': 0, 'grid': 0, 'battery': 0, 'current_battery_soc': 0,
              'import_energy_delta_kwh': 0, 'export_energy_delta_kwh': 0, 'self_consumption_energy_delta_kwh': 0}

    def register(title, value):
        print("%s: %s" % (title, value))
        normalized = title.lower().replace(" ", "_").replace("(", "").replace(")", "").replace("-", "_")
        if normalized == "grid_import":
            normalized = "grid"
        if normalized == "battery_charge":
            normalized = "battery"
        if normalized == "battery_discharge":
            normalized = "battery"
            value = -value
        if normalized == "grid_export":
            normalized = "grid"
            value = -value
        result[normalized] = value

    ##
    for idx, p in enumerate(filtered):
        param, title, _ = p
        # print("chart # %s" % str(idx))
        req_dashboard_1 = http.request(
            'POST',
            '%s/h/chart' % API_URL,
            headers={
                'Authorization': 'Bearer ' + token,
            },
            body=json.dumps(param)
        )
        resp_dashboard_1 = json.loads(req_dashboard_1.data.decode('utf-8'))
        series = resp_dashboard_1["series"]

        if "links" in series:
            links = series["links"]
            for link in links:
                register(link["id"], link["value"])
        elif "dataset" in resp_dashboard_1:
            legend = ["Timestamp"] + [e["name"] for e in series]
            points = resp_dashboard_1["dataset"]["source"]
            merged = [dict(zip(legend, p)) for p in points]
            print(merged)
        elif type(series) is list:
            for element in series:
                if "data" in element:
                    for d in element["data"]:
                        if "name" in d:
                            register(d["name"], d["value"])
                        else:
                            register(title, d["value"])

        with open('resp_chart_%d.json' % idx, "w") as f:
            f.write(json.dumps(resp_dashboard_1, indent=2))

    ##
    device_id = resp_dashboard["rows"][0]["cells"][0]["widget"]["datafetch"]["parameters"]["deviceId"]
    req_overview = http.request(
        'GET',
        '%s/h/devices/%s/widgets/overview' % (API_URL, device_id,),
        headers={
            'Authorization': 'Bearer ' + token,
        }
    )
    resp_overview = json.loads(req_overview.data.decode('utf-8'))
    with open('resp_overview.json', "w") as f:
        f.write(json.dumps(resp_overview, indent=2))
    filtered = filter(lambda p: p[2] == "table", extract_requests(resp_overview))

    for idx, p in enumerate(filtered):
        param, title, _ = p
        param["opts"] = {"rows": [], "columns": [],
                         "options": {"defaultColDef": {"sortable": True, "resizable": True, "filter": True, "flex": 1}}}
        # print("chart # %s" % str(idx))
        req_dashboard_1 = http.request(
            'POST',
            '%s/h/table' % API_URL,
            headers={
                'Authorization': 'Bearer ' + token,
            },
            body=json.dumps(param)
        )
        resp_table_1 = json.loads(req_dashboard_1.data.decode('utf-8'))
        names = []
        values = []
        for d in resp_table_1["dataset"]["cols"][1:]:
            names.append(d["name"])
        for d in resp_table_1["dataset"]["rows"][0][1:]:
            values.append(d)
        for (k, v) in zip(names, values):
            register("tbl_" + k, v)
        with open('resp_table_%d.json' % idx, "w") as f:
            f.write(json.dumps(resp_table_1, indent=2))

    ##
    result["timestamp"] = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    with open('qc-readings.json', "w") as f:
        f.write(json.dumps(result, indent=2))


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        data = json.loads(f.read())
        login = data['login']
        pw = data['password']
        fetch_qc_data(login, pw)
