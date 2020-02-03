#! /usr/bin/env python

import sys
try:
    import Globals
except:
    print "Must be run inside a Zenoss container"
    print "See the following example:"
    print "serviced service shell -i zope su - zenoss -c '/mnt/pwd/templateReport.py -c CustName -p /mnt/pwd'"
    print "\n\n"
    sys.exit(1)
import json
import optparse

from Products.ZenModel.Device import Device
from Products.ZenModel.DeviceComponent import DeviceComponent
from Products.ZenUtils.ZenScriptBase import ZenScriptBase

records = {}

p = optparse.OptionParser()
p.add_option('-p', '--path', action='store', dest='outpath')
p.set_defaults(outpath='/mnt/pwd')
p.add_option('-f', '--file', action='store', dest='outfile')
p.set_defaults(outfile="thresholds.json")
p.add_option("-c", "--customer", action="store", dest="cust_name")
opts, args = p.parse_args()
cust_name = opts.cust_name
outpath = opts.outpath
if not cust_name:
    p.print_help()
    sys.exit(1)
outfile = '-'.join((cust_name, opts.outfile))
outfile = '/'.join((outpath, outfile))
jsonout = open(outfile, "w")

# Connect to DMD
print "Trying to connect to DMD"
zenscript = ZenScriptBase(connect=True, noopts=1)
dmd = None
try:
    dmd = zenscript.dmd
    print "Connected to DMD.  Zenoss version found: %s" % dmd.version
except Exception, e:
    print "Connection to zenoss dmd failed: %s\n" % e
    sys.exit(1)


for template in dmd.Devices.getAllRRDTemplates():
    record = {}
    parent = template.getPrimaryParent()
    targetName, targetUrl = ("Unknown", parent.getPrimaryUrlPath())
    zenpack = getattr(template.pack(), 'id', 'None')
    if parent.id == 'rrdTemplates':
        targetName = parent.getPrimaryParent().getOrganizerName()
        targetUrl = parent.getPrimaryParent().getPrimaryUrlPath()
    elif isinstance(parent, Device):
        targetName = parent.getId()
    elif isinstance(parent, DeviceComponent):
        targetName = "%s/%s" % (parent.device().getId(), parent.name())
    for threshold in template.thresholds():
        thresholdClass = threshold.__class__.__name__
        print threshold.getPrimaryUrlPath(), thresholdClass
        record = {
            'name': threshold.id,
            'targetName': targetName,
            'targetUrl': targetUrl,
            'zenpack': zenpack,
            'templateName': template.getId(),
            'templateUrl': template.getPrimaryUrlPath(),
            'thresholdUrl': threshold.getPrimaryUrlPath(),
            'severity': threshold.severity,
            'enabled': threshold.enabled,
            'thresholdClass': thresholdClass,
            'metaType': threshold.meta_type,
            'creator': threshold.creator(),
            'title': threshold.title,
            'description': threshold.description,
            'datapoints': threshold.dsnames,
            'severity': threshold.severity,
            'eventClass': threshold.eventClass,
        }
        if thresholdClass != 'CiscoStatus' and thresholdClass != 'ValueChangeThreshold' and thresholdClass != 'HPStatus':
            record['explanation'] = getattr(threshold, 'explanation', 'N/A')
            record['resolution'] = getattr(threshold, 'resolution', 'N/A')
            record['escalateCount'] = getattr(threshold, 'escalateCount', 'N/A')
        
        if thresholdClass == 'MinMaxThreshold':
            record['minval'] = threshold.minval
            record['minval'] = threshold.maxval
        elif thresholdClass == 'CiscoStatus' or thresholdClass == 'VSphereStatusThreshold':
            record['eventClassKey'] = threshold.eventClassKey
        elif thresholdClass == 'DurationThreshold':
            record['minval'] = threshold.minval
            record['minval'] = threshold.maxval
            record['timePeriod'] = threshold.timePeriod
            record['violationPercentage'] = threshold.violationPercentage
        elif thresholdClass == 'PredictiveThreshold':
            record['aggregateFunction'] = threshold.aggregateFunction
            record['projectionAlgorithm'] = threshold.projectionAlgorithm
            record['projectionParameters'] = threshold.projectionParameters
            record['pastData'] = threshold.pastData
            record['pastDataUnits'] = threshold.pastDataUnits
            record['amountToPredict'] = threshold.amountToPredict
            record['amountToPredictUnit'] = threshold.amountToPredictUnits
            record['minval'] = threshold.minval
            record['maxval'] = threshold.maxval
        records[threshold.getPrimaryUrlPath()] = record
       
jsonout.write(json.dumps(records))
jsonout.close

