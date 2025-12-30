public with sharing class LeadQueueCacheRepository {
    private static final Integer ASSIGNMENT_TTL_SECONDS = 1800; // 30 minutes
    private static final Integer QUEUE_CACHE_TTL_SECONDS = 300; // Platform Cache minimum TTL is 300 seconds.
    private static final String CACHE_PARTITION = 'local.LeadQueueCache';
    private static final String ASSIGNMENT_CACHE_PREFIX = 'assign';
    private static final String USER_CACHE_PREFIX = 'user';
    private static final String QUEUE_CACHE_PREFIX = 'queue';

    @TestVisible private static Boolean simulateCacheAvailability = false;
    @TestVisible private static Map<String, String> simulatedRecordAssignments = new Map<String, String>();
    @TestVisible private static Map<String, String> simulatedUserAssignments = new Map<String, String>();
    @TestVisible private static Map<String, Long> simulatedAssignmentTimestamps = new Map<String, Long>();

    public static Boolean isSimulatedCacheActive() {
        return Test.isRunningTest() && simulateCacheAvailability;
    }

    @TestVisible
    public static void resetSimulatedCache() {
        simulatedRecordAssignments.clear();
        simulatedUserAssignments.clear();
        simulatedAssignmentTimestamps.clear();
    }

    @TestVisible
    public static void enableCacheSimulation(Boolean shouldSimulate) {
        System.assert(Test.isRunningTest(), 'Cache simulation can only be enabled during tests');
        simulateCacheAvailability = shouldSimulate;
        if (!shouldSimulate) {
            resetSimulatedCache();
        }
    }

    public static Boolean isCacheConfigured() {
        return getPartition() != null || isSimulatedCacheActive();
    }

    public static Cache.OrgPartition getPartition() {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition == null) {
                LeadQueueLogging.debug('Cache partition not available for user: ' + UserInfo.getUserId());
                return null;
            }
            return partition;
        } catch (Exception e) {
            LeadQueueLogging.debug('Cache partition error for user ' + UserInfo.getUserId() + ': ' + e.getMessage());
            return null;
        }
    }

    private static String normalizeCacheToken(String value) {
        return String.isBlank(value) ? '_' : value.trim();
    }

    public static String buildQueueCacheKey(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, Integer pageNumber, Integer pageSize, String tileFilter) {
        List<String> parts = new List<String>{
            QUEUE_CACHE_PREFIX,
            UserInfo.getUserId(),
            String.valueOf(showScheduledCalls),
            String.valueOf(pageNumber),
            String.valueOf(pageSize),
            normalizeCacheToken(statusFilter),
            normalizeCacheToken(caseTypeFilter),
            normalizeCacheToken(dueDateFilter),
            normalizeCacheToken(tileFilter)
        };
        String rawKey = String.join(parts, '|');
        Blob digest = Crypto.generateDigest('SHA1', Blob.valueOf(rawKey));
        return QUEUE_CACHE_PREFIX + EncodingUtil.convertToHex(digest);
    }

    public static LeadQueueModels.QueueResponse getQueueResponse(String cacheKey) {
        if (Test.isRunningTest()) {
            return null;
        }
        Cache.OrgPartition orgCache = getPartition();
        if (orgCache == null) {
            return null;
        }
        String raw;
        try {
            raw = (String) orgCache.get(cacheKey);
        } catch (Exception e) {
            LeadQueueLogging.debug('LeadQueueCacheRepository cache get error: ' + e.getMessage());
            return null;
        }
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            LeadQueueModels.QueueResponseCache cached = (LeadQueueModels.QueueResponseCache) JSON.deserialize(raw, LeadQueueModels.QueueResponseCache.class);
            return cached != null ? cached.toResponse() : null;
        } catch (Exception e) {
            LeadQueueLogging.debug('LeadQueueCacheRepository cache deserialize error: ' + e.getMessage());
            orgCache.remove(cacheKey);
            return null;
        }
    }

    public static void putQueueResponse(String cacheKey, LeadQueueModels.QueueResponse response) {
        if (Test.isRunningTest()) {
            return;
        }
        Cache.OrgPartition orgCache = getPartition();
        if (orgCache == null || response == null) {
            return;
        }
        try {
            LeadQueueModels.QueueResponseCache cached = new LeadQueueModels.QueueResponseCache().fromResponse(response);
            orgCache.put(cacheKey, JSON.serialize(cached), QUEUE_CACHE_TTL_SECONDS);
        } catch (Exception e) {
            LeadQueueLogging.debug('LeadQueueCacheRepository cache serialize error: ' + e.getMessage());
        }
    }

    public static Boolean isRecordAssigned(String recordId) {
        try {
            if (isSimulatedCacheActive()) {
                return simulatedRecordAssignments.containsKey(recordId);
            }
            Cache.OrgPartition orgCache = getPartition();
            if (orgCache == null) {
                return false;
            }
            String assignmentJson = (String) orgCache.get(ASSIGNMENT_CACHE_PREFIX + recordId);
            return assignmentJson != null;
        } catch (Exception e) {
            return false;
        }
    }

    public static Map<String, Object> getAssignmentData(String recordId) {
        try {
            if (isSimulatedCacheActive()) {
                if (!simulatedRecordAssignments.containsKey(recordId)) {
                    return null;
                }
                Map<String, Object> simulatedData = new Map<String, Object>{
                    'userId' => simulatedRecordAssignments.get(recordId)
                };
                if (simulatedAssignmentTimestamps.containsKey(recordId)) {
                    simulatedData.put('assignedAt', simulatedAssignmentTimestamps.get(recordId));
                }
                return simulatedData;
            }
            Cache.OrgPartition orgCache = getPartition();
            if (orgCache == null) {
                return null;
            }
            String assignmentJson = (String) orgCache.get(ASSIGNMENT_CACHE_PREFIX + recordId);
            if (String.isBlank(assignmentJson)) {
                return null;
            }
            return (Map<String, Object>) JSON.deserializeUntyped(assignmentJson);
        } catch (Exception e) {
            LeadQueueLogging.debug('Error getting assignment data: ' + e.getMessage());
            return null;
        }
    }

    public static Long getAssignmentTimestamp(String recordId) {
        try {
            Map<String, Object> assignmentData = getAssignmentData(recordId);
            if (assignmentData == null || !assignmentData.containsKey('assignedAt')) {
                return null;
            }
            return parseAssignmentTimestamp(assignmentData.get('assignedAt'));
        } catch (Exception e) {
            LeadQueueLogging.debug('Error getting assignment timestamp: ' + e.getMessage());
            return null;
        }
    }

    public static String getUserAssignmentId(String userId) {
        if (String.isBlank(userId)) {
            return null;
        }
        if (isSimulatedCacheActive()) {
            return simulatedUserAssignments.get(userId);
        }
        Cache.OrgPartition orgCache = getPartition();
        if (orgCache == null) {
            return null;
        }
        return (String) orgCache.get(USER_CACHE_PREFIX + userId);
    }

    public static Boolean hasUserAssignment(String userId) {
        return getUserAssignmentId(userId) != null;
    }

    public static void putAssignment(String recordId, String userId, Long assignedAt) {
        if (String.isBlank(recordId) || String.isBlank(userId)) {
            return;
        }
        if (isSimulatedCacheActive()) {
            simulatedRecordAssignments.put(recordId, userId);
            simulatedUserAssignments.put(userId, recordId);
            if (assignedAt != null) {
                simulatedAssignmentTimestamps.put(recordId, assignedAt);
            }
            return;
        }
        Cache.OrgPartition orgCache = getPartition();
        if (orgCache == null) {
            return;
        }
        Map<String, Object> assignmentData = new Map<String, Object>{
            'userId' => userId,
            'assignedAt' => assignedAt
        };
        orgCache.put(ASSIGNMENT_CACHE_PREFIX + recordId, JSON.serialize(assignmentData), ASSIGNMENT_TTL_SECONDS);
        orgCache.put(USER_CACHE_PREFIX + userId, recordId, ASSIGNMENT_TTL_SECONDS);
    }

    public static void removeRecordAssignment(String recordId) {
        if (String.isBlank(recordId)) {
            return;
        }
        if (isSimulatedCacheActive()) {
            simulatedRecordAssignments.remove(recordId);
            simulatedAssignmentTimestamps.remove(recordId);
            return;
        }
        Cache.OrgPartition orgCache = getPartition();
        if (orgCache == null) {
            return;
        }
        orgCache.remove(ASSIGNMENT_CACHE_PREFIX + recordId);
    }

    public static void removeUserAssignment(String userId) {
        if (String.isBlank(userId)) {
            return;
        }
        if (isSimulatedCacheActive()) {
            simulatedUserAssignments.remove(userId);
            return;
        }
        Cache.OrgPartition orgCache = getPartition();
        if (orgCache == null) {
            return;
        }
        orgCache.remove(USER_CACHE_PREFIX + userId);
    }

    public static Map<String, Long> getUserAssignmentData(String userId) {
        Map<String, Long> result = new Map<String, Long>();
        String assignedRecordId = getUserAssignmentId(userId);
        if (assignedRecordId != null) {
            Long timestamp = getAssignmentTimestamp(assignedRecordId);
            result.put(assignedRecordId, timestamp);
        }
        return result;
    }

    public static Long parseAssignmentTimestamp(Object rawValue) {
        if (rawValue == null) {
            return null;
        }
        if (rawValue instanceof Long) {
            return (Long) rawValue;
        }
        try {
            Decimal numericValue = Decimal.valueOf(String.valueOf(rawValue));
            return numericValue != null ? numericValue.longValue() : null;
        } catch (Exception parseError) {
            LeadQueueLogging.debug('Assignment timestamp parse error: ' + parseError.getMessage());
            return null;
        }
    }
}
