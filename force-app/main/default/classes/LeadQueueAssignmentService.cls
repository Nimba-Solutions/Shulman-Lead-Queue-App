public with sharing class LeadQueueAssignmentService {
    public static LeadQueueModels.AssignmentResult assignNextAvailableRecord(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, String tileFilter) {
        try {
            List<litify_pm__Intake__c> records = LeadQueueQueryService.getAvailableRecords(10, 0, statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, tileFilter);
            String failureMessage = null;

            if (records.isEmpty()) {
                return new LeadQueueModels.AssignmentResult(false, 'No available records in queue');
            }

            for (litify_pm__Intake__c record : records) {
                if (LeadQueueEligibilityService.isValidQueueRecord(record)) {
                    LeadQueueModels.AssignmentResult result = assignRecord(record.Id);
                    if (result.success) {
                        result.recordId = record.Id;
                        result.recordName = record.Name;
                        return result;
                    } else if (!String.isBlank(result.message)) {
                        failureMessage = result.message;
                        if (result.message.contains('Platform Cache')) {
                            return new LeadQueueModels.AssignmentResult(false, failureMessage);
                        }
                    }
                }
            }

            return new LeadQueueModels.AssignmentResult(false, failureMessage != null ? failureMessage : 'No available records could be assigned');
        } catch (Exception e) {
            LeadQueueLogging.debug('Assignment next error: ' + e.getMessage());
            return new LeadQueueModels.AssignmentResult(false, 'Assignment failed');
        }
    }

    public static LeadQueueModels.AssignmentResult assignRecord(String recordId) {
        try {
            if (String.isBlank(recordId)) {
                return new LeadQueueModels.AssignmentResult(false, 'Record ID is required');
            }

            if (!isValidSalesforceId(recordId)) {
                return new LeadQueueModels.AssignmentResult(false, 'Invalid record ID format');
            }

            if (!Schema.sObjectType.litify_pm__Intake__c.isAccessible()) {
                return new LeadQueueModels.AssignmentResult(false, 'Insufficient permissions to access intake records');
            }

            try {
                LeadQueueQueryService.validateFieldAccess();
            } catch (Exception e) {
                return new LeadQueueModels.AssignmentResult(false, 'Missing required field permissions: ' + e.getMessage());
            }

            litify_pm__Intake__c record = LeadQueueQueryService.getRecordById(recordId);
            if (record == null) {
                return new LeadQueueModels.AssignmentResult(false, 'Record not found or not accessible');
            }

            String userId = UserInfo.getUserId();
            Cache.OrgPartition orgCache = LeadQueueCacheRepository.getPartition();
            Boolean useSimulatedCache = orgCache == null && LeadQueueCacheRepository.isSimulatedCacheActive();

            if (orgCache == null && !useSimulatedCache) {
                LeadQueueLogging.debug('LeadQueueAssignmentService.assignRecord: Platform Cache unavailable for user ' + userId + ' and record ' + recordId);
                return new LeadQueueModels.AssignmentResult(false, 'Platform Cache not configured. Please contact your administrator.');
            }

            if (LeadQueueCacheRepository.isRecordAssigned(recordId)) {
                return new LeadQueueModels.AssignmentResult(false, 'Record already assigned to another user');
            }

            if (!LeadQueueEligibilityService.isEligibleForAssignment(record)) {
                return new LeadQueueModels.AssignmentResult(false, 'Record is not eligible for Lead Queue assignment');
            }

            if (LeadQueueCacheRepository.hasUserAssignment(userId)) {
                return new LeadQueueModels.AssignmentResult(false, 'User already has an assigned record. Release current assignment first.');
            }

            Long assignedAt = Datetime.now().getTime();
            LeadQueueCacheRepository.putAssignment(recordId, userId, assignedAt);
            return new LeadQueueModels.AssignmentResult(true, 'Record assigned successfully');

        } catch (Exception e) {
            LeadQueueLogging.debug('Assignment record error: ' + e.getMessage());
            return new LeadQueueModels.AssignmentResult(false, 'Assignment failed');
        }
    }

    public static Boolean releaseUserAssignments(String recordId) {
        try {
            String userId = UserInfo.getUserId();
            Boolean released = false;
            String normalizedRecordId = normalizeRecordId(recordId);

            String assignedRecord = LeadQueueCacheRepository.getUserAssignmentId(userId);
            if (assignedRecord != null) {
                LeadQueueCacheRepository.removeRecordAssignment(assignedRecord);
                released = true;
            }
            LeadQueueCacheRepository.removeUserAssignment(userId);
            if (!released && normalizedRecordId != null) {
                Map<String, Object> assignmentData = LeadQueueCacheRepository.getAssignmentData(normalizedRecordId);
                String assignedUserId = assignmentData != null ? (String) assignmentData.get('userId') : null;
                if (assignedUserId == userId) {
                    LeadQueueCacheRepository.removeRecordAssignment(normalizedRecordId);
                    released = true;
                }
            }

            return true;

        } catch (Exception e) {
            LeadQueueLogging.debug('Release assignments error: ' + e.getMessage());
            throw new AuraHandledException('Error releasing assignments');
        }
    }

    public static Map<String, Long> getUserAssignmentData() {
        try {
            String userId = UserInfo.getUserId();
            return LeadQueueCacheRepository.getUserAssignmentData(userId);
        } catch (Exception e) {
            LeadQueueLogging.debug('User assignments error: ' + e.getMessage());
            return new Map<String, Long>();
        }
    }

    public static LeadQueueModels.AssignedRecordSummary getAssignedRecordSummary(String recordId) {
        try {
            if (String.isBlank(recordId) || !isValidSalesforceId(recordId)) {
                return null;
            }

            if (!Schema.sObjectType.litify_pm__Intake__c.isAccessible()) {
                return null;
            }

            String query = 'SELECT Id, Name, litify_pm__Display_Name__c, litify_pm__Status__c' +
                ' FROM litify_pm__Intake__c WHERE Id = :recordId LIMIT 1';
            Map<String, Object> bindVars = new Map<String, Object>{ 'recordId' => recordId };
            List<litify_pm__Intake__c> records = Database.queryWithBinds(query, bindVars, AccessLevel.USER_MODE);
            if (records.isEmpty()) {
                return null;
            }

            litify_pm__Intake__c record = records[0];
            LeadQueueModels.AssignedRecordSummary summary = new LeadQueueModels.AssignedRecordSummary();
            summary.recordId = record.Id;
            summary.displayName = String.isNotBlank(record.litify_pm__Display_Name__c)
                ? record.litify_pm__Display_Name__c
                : record.Name;
            summary.status = record.litify_pm__Status__c;
            return summary;
        } catch (Exception e) {
            LeadQueueLogging.debug('getAssignedRecordSummary error: ' + e.getMessage());
            return null;
        }
    }

    public static List<String> getUserAssignedRecordIds() {
        Map<String, Long> assignmentData = getUserAssignmentData();
        return new List<String>(assignmentData.keySet());
    }

    public static void autoReleaseRecords(List<Id> recordIds) {
        try {
            Boolean didRelease = false;
            if (!LeadQueueCacheRepository.isCacheConfigured()) {
                LeadQueueLogging.debug('LeadQueueAssignmentService.autoReleaseRecords: Platform Cache unavailable - assignment tracking limited for ' + recordIds.size() + ' records');
                return;
            }

            for (Id recordId : recordIds) {
                Map<String, Object> assignmentData = LeadQueueCacheRepository.getAssignmentData(recordId);
                String assignedUserId = assignmentData != null ? (String) assignmentData.get('userId') : null;
                if (assignmentData != null) {
                    didRelease = true;
                }

                LeadQueueCacheRepository.removeRecordAssignment(recordId);

                if (!String.isBlank(assignedUserId)) {
                    LeadQueueCacheRepository.removeUserAssignment(assignedUserId);
                    LeadQueueLogging.debug('Auto-released record: ' + recordId + ' from user: ' + assignedUserId);
                    didRelease = true;
                }
            }
        } catch (Exception e) {
            LeadQueueLogging.debug('Auto-release error: ' + e.getMessage());
        }
    }

    public static void handleIntakeFieldChanges(List<litify_pm__Intake__c> newRecords, Map<Id, litify_pm__Intake__c> oldRecordsMap) {
        Set<Id> recordsToRelease = new Set<Id>();

        for (litify_pm__Intake__c newRecord : newRecords) {
            litify_pm__Intake__c oldRecord = oldRecordsMap.get(newRecord.Id);

            if (newRecord.Appointment_Date__c != oldRecord.Appointment_Date__c ||
                newRecord.Follow_Up_Date_Time__c != oldRecord.Follow_Up_Date_Time__c) {
                recordsToRelease.add(newRecord.Id);
            }
        }

        if (!recordsToRelease.isEmpty()) {
            autoReleaseRecords(new List<Id>(recordsToRelease));
        }
    }

    private static String normalizeRecordId(String recordId) {
        if (String.isBlank(recordId)) {
            return null;
        }
        String trimmedRecordId = recordId.trim();
        if (trimmedRecordId.endsWith('-assigned')) {
            trimmedRecordId = trimmedRecordId.substring(0, trimmedRecordId.length() - 9);
        }
        return isValidSalesforceId(trimmedRecordId) ? trimmedRecordId : null;
    }

    private static Boolean isValidSalesforceId(String recordId) {
        if (String.isBlank(recordId)) {
            return false;
        }
        String trimmedId = recordId.trim();
        Integer length = trimmedId.length();
        if (length != 15 && length != 18) {
            return false;
        }
        if (!Pattern.matches('^[a-zA-Z0-9]{15,18}$', trimmedId)) {
            return false;
        }
        return trimmedId.replace('0', '').length() > 0;
    }
}
