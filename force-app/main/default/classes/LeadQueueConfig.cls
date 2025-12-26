public class LeadQueueConfig {
    public static final List<String> STATUS_ORDER = new List<String>{
        'Lead Generated',
        'Intake Scheduled',
        'In Contact/Under Review',
        'Missed Appointment',
        'Intake Package Sent',
        'Attempting to Contact',
        'Questionnaire',
        'Pending Referral'
    };

    public static final Integer DEFAULT_STATUS_PRIORITY = 99;
    public static final Map<String, Integer> STATUS_PRIORITY = buildStatusPriority();

    public static final Map<String, Integer> CASE_TYPE_PRIORITY = new Map<String, Integer>{
        'Labor Law' => 1,
        'MVA' => 2,
        'Premises' => 3,
        'WC & PI' => 4,
        'Personal Injury' => 5,
        'Worker Compensation' => 6,
        'Other' => 7,
        'Medical Malpractice' => 9,
        'Employment Law' => 10,
        'Federal Workers\' Compensation' => 11,
        'Immigration' => 12,
        'Mass Tort/Product Liability' => 13,
        'Real Estate/Closings' => 14,
        'Landlord-Tenant' => 15,
        'Family Law' => 16,
        'Estate Planning' => 17,
        'Business/Corporate' => 18,
        'Criminal Defense' => 19,
        'Traffic' => 20,
        'Veteran Disability' => 21
    };
    
    public static final Integer DEFAULT_CASE_TYPE_PRIORITY = 8;

    public static Integer getCaseTypePriority(String caseType) {
        Integer priority = CASE_TYPE_PRIORITY.get(caseType);
        return priority != null ? priority : DEFAULT_CASE_TYPE_PRIORITY;
    }

    public static Integer getStatusPriority(String status) {
        Integer priority = STATUS_PRIORITY.get(status);
        return priority != null ? priority : DEFAULT_STATUS_PRIORITY;
    }

    public static Integer calculatePriorityScore(String status, Integer caseTypePriority) {
        Integer statusPriority = getStatusPriority(status);
        Integer safeCasePriority = caseTypePriority != null ? caseTypePriority : DEFAULT_CASE_TYPE_PRIORITY;
        return (statusPriority * 10) + safeCasePriority;
    }

    public static Integer calculatePriorityScore(String status, String caseType) {
        Integer casePriority = getCaseTypePriority(caseType);
        return calculatePriorityScore(status, casePriority);
    }

    // Use only explicit Case Type values; leave empty when not provided.
    public static String normalizeCaseType(String intakeType, String caseType) {
        return String.isNotBlank(caseType) ? caseType : null;
    }

    private static Map<String, Integer> buildStatusPriority() {
        Map<String, Integer> result = new Map<String, Integer>();
        Integer counter = 1;
        for (String status : STATUS_ORDER) {
            result.put(status, counter);
            counter++;
        }
        return result;
    }
}
